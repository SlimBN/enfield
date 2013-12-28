async      = require 'async'
fs         = require 'fs-extra'
gaze       = require 'gaze'
glob       = require 'glob'
log        = require 'npmlog'
path       = require 'path'
time       = require('time')(Date) # Extend global object
tinyliquid = require 'tinyliquid'
toposort   = require 'toposort'
Q          = require 'q'

helpers    = require './helpers'

# Built-in plugins
bundledPlugins = null
# Regexp for matching post filenames
postMask = null
# Global reference for custom tags
currentState = null

INCLUDE_PATH = '_includes'

module.exports = exports = (config, callback) ->
  log.info "generate", "Begin generation"
  # First-run initialization
  postMask = ///^(\d{4})-(\d{2})-(\d{2})-(.+)\.(#{config.markdown_ext.join '|'}|html)$///
  time.tzset config.timezone
  Q.all([checkDirectories(config), loadBundledPlugins()])
    .then ->
      Q.nfcall refreshContent, config
    .then ->
      log.info "generate", "Generated %s -> %s", config.source, config.destination
      callback()
      return unless config.watch

      destinationPath = path.resolve config.destination
      gaze path.join(config.source, '**/*'), {debounceDelay: 500}, (err, watcher) ->
        log.info "watch", "Watching %s for changes", config.source
        watcher.on 'all', (event, filepath) ->
          # Ignore any path within the destination directory
          return if helpers.isWithinDirectory filepath, destinationPath

          # Ignore any path within hidden/ignored directories

          # TODO: Special case _config.yml
          # TODO: Reload plugins

          log.info "watch", "%s %s", event, filepath
          refreshContent config, ->
            log.info "watch", "Regenerated"
    .fail (err) ->
      callback err

refreshContent = (config, callback) ->
  log.silly "generate", "Refreshing content"

  # Get content in parallel:
  Q.all([
    # Mimic Jekyll behavior by clearing out destination before regeneration
    Q.nfcall fs.remove, config.destination
    loadSitePlugins(config)
    Q.nfcall loadIncludes, config
    Q.nfcall loadLayouts, config
    Q.nfcall loadContents, config
  ])
    .then ([_, plugins, includes, layouts, { posts, pages, files }]) ->
      log.verbose "generate", "Initial content load complete"
      processResults {config, plugins, includes, layouts, posts, pages, files}, callback
    .fail (err) -> callback err

processResults = ({config, plugins, includes, layouts, posts, pages, files}, callback) ->
  # Create site data structure
  site = {
    time: Date.now()
    config
    posts
    pages
    static_files: files
    tags: {}
    categories: {}
  }

  # Setup current state
  currentState = {
    site
    page: null
    liquidOptions: null
  }

  # Add all values from config, but make sure not to clobber any existing
  for key, value of config
    unless key of site
      site[key] = value

  # Collect tags & categories for posts
  for type in ['tags', 'categories']
    for post in posts
      continue unless (config.future or post.published) and post[type]?.length
      for value in post[type]
        site[type][value] or= { name: value, posts: [] }
        site[type][value].posts.push post

  # Prepare plugins
  mergedPlugins = mergePlugins bundledPlugins, plugins

  liquidOptions = currentState.liquidOptions =
    customTags: mergedPlugins.tags

  # Create base context for tinyliquid
  context = tinyliquid.newContext {
    locals: {
      site
    }
    filters: mergedPlugins.filters
  }

  # Handle {% include %} tags
  context.onInclude (name, callback) ->
    log.silly "generate", "Fetching include for %s", name
    ast = tinyliquid.parse includes[name], liquidOptions
    callback null, ast

  convertIncludes includes, mergedPlugins.converters, (err) ->
    if err then return callback err

    # Compile layouts
    compiledLayouts = {}
    for name, {data, content} of layouts
      try
        compiledLayouts[name] = tinyliquid.compile content, liquidOptions
      catch err
        callback new Error "Error while compiling layout: #{err.message}"
        return

    log.verbose "generate", "Reading complete. Preparing to write"

    # Run generators
    async.forEachSeries(
      mergedPlugins.generators,
      (generator, cb) -> generator site, cb
      (err) ->
        if err then return callback err

        # Filter out any files blanked by generators
        site.static_files = site.static_files.filter (f) -> !!f

        # Now write all content to disk
        bundle = { site, config, liquidOptions, compiledLayouts, mergedPlugins, context }
        async.series([
          # Write posts before pages, since pagination, etc depend on
          # post-conversion HTML
          (cb) -> writePages site.posts, bundle, cb
          (cb) -> writePages site.pages, bundle, cb
          (cb) -> writeFiles bundle, cb
        ], callback)
    )

writePages = (pages, bundle, callback) ->
  async.forEachLimit(
    pages
    5
    (page, cb) -> writePage page, bundle, cb
    callback
  )

writePage = (page, bundle, callback) ->
  log.verbose "generate", "writePage %s", page.url
  { site, config, liquidOptions, compiledLayouts, mergedPlugins, context } = bundle

  currentState.page = page

  # Respect published file
  return callback() unless config.future or page.published

  ext = path.extname page.path

  # Run conversion
  convertContent ext, page.content, mergedPlugins.converters, (err, result) ->
    if err then return callback err

    log.verbose "generate", "Processing %s (%s)", page.title, page.url

    page.content = result.content
    newExt = result.ext or page.ext
    paginator = page.paginator or {}

    # Pretty URLs don't get extensions
    if config.pretty_urls and newExt is '.html'
      page.url = helpers.stripExtension page.url
    else if newExt isnt ext
      # Update page url with new extension
      page.url = (helpers.stripExtension page.url) + newExt


    # Strip out index.html
    if path.basename(page.url, '.html') is 'index'
      page.url = path.dirname page.url

    # Set up correct path / URL
    outpath = path.join config.destination, page.url
    unless path.extname page.url
      if newExt is '.html'
        outpath = path.join config.destination, page.url, 'index.html'

    context.setLocals 'page', page
    context.setLocals 'paginator', paginator

    # Content may contain liquid directives (such as a post listing). Process
    # now before layout
    render = tinyliquid.compile page.content, liquidOptions
    render context, (err) ->
      if err
        log.verbose "generate", "Tinyliquid compile error: %s", err.message
        callback new Error "Error while processing #{page.url}: #{err.message}"
        return

      log.silly "generate", "Rendered page content for %s", page.url
      page.content = context.clearBuffer().toString()

      # If there's no layout, then we're done
      unless page.layout and page.layout of compiledLayouts
        log.verbose "generate", "Writing file without layout: %s", outpath
        fs.outputFile outpath, page.content, callback
        return

      log.verbose "generate", "Applying layout %s to %s", page.layout, page.url
      template = compiledLayouts[page.layout]
      context.setLocals 'content', page.content
      template context, (err) ->
        if err
          log.verbose "generate", "Tinyliquid compile error: %s", err.message
          callback new Error "Error while processing #{page.url}: #{err.message}"
          return

        # Write file
        log.verbose "generate", "Writing file: %s", outpath
        fs.outputFile outpath, context.clearBuffer(), callback

writeFiles = (bundle, callback) ->
  log.verbose "generate", "Writing static files"
  { site, config, liquidOptions, compiledLayouts } = bundle
  async.forEachLimit(
    site.static_files
    5
    (filepath, cb) ->
      relpath = helpers.stripDirectoryPrefix filepath, config.source
      outpath = path.join config.destination, relpath
      log.verbose "generate", "Copying %s -> %s", filepath, outpath
      fs.mkdirs path.dirname outpath
      fs.copy filepath, outpath, cb
    callback
  )

convertContent = (ext, content, converters, callback) ->
  for converter in converters
    if converter.matches ext
      converter.convert content, (err, converted) ->
        if err then return callback err
        callback null, {
          ext: converter.outputExtension ext
          content: converted
        }
      return

  # No converter found, leave unmodified
  callback null, { ext, content }

mergePlugins = (a, b) ->
  merged =
    filters: {}
    tags: {}
    converters: []
    generators: []

  for set in [a, b]
    merged.converters = merged.converters.concat set.converters
    merged.generators = merged.generators.concat set.generators
    for name, filter of set.filters
      merged.filters[name] = filter
    for name, fn of set.tags
      # Wrap custom tags in a simpler API
      log.silly "generate", "Creating wrapper for custom tag %s", name
      do (name, fn) ->
        merged.tags[name] = (context, name, body) ->
          # Call the plugin function using a much simpler API
          # Need to set page and site variables before running liquid conversion
          result = fn body, currentState.page, currentState.site

          # Use tinyliquid helper method to output HTML
          context.astStack.push tinyliquid.parse result, currentState.liquidOptions

  # Converters are sorted by priority
  merged.converters.sort (a, b) -> b.priority - a.priority

  merged

loadIncludes = (config, callback) ->
  includeDir = path.join config.source, INCLUDE_PATH

  log.verbose "generate", "Looking for includes in %s", includeDir
  includes = {}

  getRawIncludes config, (err, files) ->
    if err then return callback err

    log.verbose "generate", "Found includes: %s", Object.keys(files).join ', '

    normalized = {}
    # Normalize all paths, stripping out file extension
    for file, {data, content} of files
      normalized[helpers.stripDirectoryPrefix file, includeDir] = content

    log.verbose "generate", "Normalized includes: %s", Object.keys(normalized).join ', '
    callback null, normalized

convertIncludes = (includes, converters, callback) ->
  async.forEach(
    Object.keys includes
    (includeName, cb) ->
      convertContent path.extname(includeName), includes[includeName], converters, (err, result) ->
        if err then return callback err
        includes[includeName] = result.content
        cb()
    callback
  )

loadLayouts = (config, callback) ->
  log.verbose "generate", "Loooking for layouts in %s", config.layouts
  layouts = {}

  getRawLayouts config, (err, files) ->
    if err then return callback err

    normalized = {}
    # Normalize all paths, stripping out file extension
    for file, {data, content} of files
      normalized[normalizeLayoutName file, config.layouts] = { data, content }
      if data?.layout
        data.layout = normalizeLayoutName data.layout, config.layouts

    # Now calculate dependency graph
    dependencyGraph = []
    for file, { data, content } of normalized
      # Skip files that don't have layout, and just use content as-is
      unless data and data.layout
        layouts[file] = { data, content }
        continue

      fullPath = path.resolve file, data.layout
      if data.layout of normalized
        dependencyGraph.push [file, data.layout]
      else
        log.warn "generate", "Can't find parent layout %s for layout %s", data.layout, file

    # Make sure to resolve files in order
    try
      sorted = toposort(dependencyGraph).reverse()
    catch err
      callback new Error "Cyclic dependency within layouts"
      return

    # Now apply layout to the layout. Can't use liquid for this since we are
    # just substituting {{ content }} in the layout
    for file in sorted
      # Skip if already done
      continue if file of layouts

      { data, content } = normalized[file]
      parent = layouts[data.layout]
      # Run replacement
      if parent
        content = parent.content.replace /\{\{\s*content\s*\}\}/, content

      layouts[file] = {data, content}

    log.verbose "generate", "Load layouts complete"
    callback null, layouts

getRawIncludes = (config, callback) ->
  includes = path.join config.source, INCLUDE_PATH
  fs.exists includes, (exists) ->
    unless exists
      log.verbose "generate", "Missing include directory: %s", includes
      return callback null, {}

    helpers.mapFiles(
      path.join(includes, '**/*')
      helpers.getMetadataAndContent
      callback
    )

getRawLayouts = (config, callback) ->
  fs.exists config.layouts, (exists) ->
    unless exists
      log.warn "generate", "Missing layout directory: %s", config.layouts
      return callback null, {}

    helpers.mapFiles(
      path.join(config.layouts, '**/*')
      helpers.getMetadataAndContent
      callback
    )

normalizeLayoutName = (name, layoutDir) ->
  # Remove extension
  name = helpers.stripExtension name
  helpers.stripDirectoryPrefix name, layoutDir

loadContents = (config, callback) ->
  helpers.getFileList(
    path.join(config.source, '**/*')
    (err, files) ->
      # Segregate files into posts and non-posts (pages and static files)
      { posts, others } = filterFiles config, files

      async.parallel [
        (cb) -> loadPosts config, posts, cb
        (cb) -> loadOthers config, others, cb
      ], (err, [posts, { pages, files }]) ->
        log.verbose "generate", "Content loading complete"
        callback null, { posts, pages, files }
  )

loadPosts = (config, files, callback) ->
  posts = []
  log.verbose "generate", "Loading posts %s", files.join ', '
  async.forEachLimit(
    files
    5
    (file, cb) -> loadPost config, file, (err, post) -> posts.push post; cb err
    (err) ->
      if err then return callback err
      # Sort posts by date
      posts = posts.sort (a, b) -> b.date - a.date
      # Setup previous / next on each post
      prev = null
      for post in posts
        # Now that the list is in chronological order, the previous post in the
        # loop is actually the older post, and therefore "next".
        if prev
          post.next = prev
          prev.prev = post
        prev = post

      # Ruby arrays have .first and .last, which some templates depend upon
      posts.first = posts[0]
      posts.last = posts[posts.length - 1]

      callback null, posts
  )

loadPost = (config, file, callback) ->
  log.silly "generate", "Loading post: %s", file
  helpers.getMetadataAndContent file, (err, val) ->
    if err then return callback err
    { data, content } = val
    match = path.basename(file).match postMask

    # Posts always have metadata
    data or= {}
    # Save original filepath
    data.path = file
    # Posts are published by default
    unless 'published' of data
      data.published = true
    # Date comes from filename and gets parsed with at noon in timezone
    data.date = new Date match[1], match[2] - 1, match[3], 12, 0, 0, 0, 0
    slug = match[4]
    # Tags
    if data.tags and typeof data.tags is 'string'
      data.tags = data.tags.split /\s+/
    # Alias category to categories
    if data.category and not data.categories
      data.categories = data.category
      delete data.category
    # Categories
    if data.categories and typeof data.categories is 'string'
      data.categories = data.categories.split /\s+/
    # Add any categories from the directory
    directoryCategories = path.dirname(file).split('/').filter (f) -> f isnt '_posts'
    if directoryCategories.length
      data.categories = (data.categories or []).concat directoryCategories
    # Calculate the permalink
    data.url = getPermalink slug, data, config.permalink
    # Use permalink as unique ID
    data.id = data.url

    data.content = content

    log.silly "generate", "Post loading complete: %s", file
    callback null, data

getPermalink = (slug, data, permalinkStyle) ->
  return permalinkStyle
    .replace(':year', data.date.getFullYear())
    .replace(':month', helpers.twoDigitPad data.date.getMonth() + 1)
    .replace(':day', helpers.twoDigitPad data.date.getDate())
    .replace(':title', slug)
    .replace(':categories', if data.categories then data.categories.join '/' else '')
    .replace(':i_month', data.date.getMonth + 1)
    .replace(':i_day', data.date.getDate())
    .replace('//', '/')

# Generate a list of pages and static files
loadOthers = (config, others, callback) ->
  pages = []
  files = []
  async.forEachLimit(
    others
    5
    (file, cb) ->
      helpers.getMetadataAndContent file, (err, val) ->
        if err then return cb err

        # Nothing to do with static files
        { data, content } = val
        unless data
          files.push file
          return cb()

        # Pages are published by default
        unless 'published' of data
          data.published = true
        # Save original filepath
        data.path = helpers.stripDirectoryPrefix file, config.source
        # Use path as ID since it should be pretty stable
        data.id = data.path
        # Use filepath as URL at first (gets changed during output)
        data.url = "/" + data.path
        # Use permalink as id
        data.id = data.url

        data.content = content

        # Add to collection
        pages.push data

        cb()
    (err) ->
      if err then return callback err
      callback null, { pages, files }
  )


filterFiles = (config, files) ->
  posts = []
  others = []
  # Segregate files into posts and non-posts (pages and static files)
  files.forEach (file) ->
    isPost = false
    for dir in file.split '/'
      # Save out posts
      if dir is '_posts'
        isPost = true
        continue
      # Hidden file?
      else if (dir not in config.include) and
              (dir[0] is '_' or dir[0] is '.' or dir in config.exclude)
        return

    if isPost
      posts.push file
    else
      others.push file

  # Filter any posts that don't match the filename pattern
  posts = posts.filter (file) -> postMask.test path.basename file

  { posts, others }

checkDirectories = (config) ->
  Q.all [
    checkSourceDirectory config.source
    checkDestinationDirectory config.destination
  ]

# Must exist and be a directory
checkSourceDirectory = (dir) ->
  log.silly "generate", "Checking for source directory %s", dir
  deferred = Q.defer()
  dir or= '.'
  isDirectory(dir)
    .then (result) ->
      if result
        deferred.resolve()
      else
        deferred.reject new Error "Source is not a directory: #{dir}"
    .fail ->
      deferred.reject new Error "Source directory does not exist: #{dir}"
  deferred.promise

# May either not exist (in which case it will be created), or must exist and be
# a directory
checkDestinationDirectory = (dir) ->
  log.silly "generate", "Checking for destination directory %s", dir
  deferred = Q.defer()
  isDirectory(dir)
    .then (result) ->
      if result
        deferred.resolve()
      else
        # Exists but isn't directory
        deferred.reject new Error "Destination is not a directory: #{dir}"
    .fail ->
      # Create the directory
      log.verbose "generate", "Creating destination directory %s", dir
      deferred.resolve Q.nfcall fs.mkdirs, dir

  deferred.promise

# True if file is directory
# False if file exists but isn't directory
# Fails if file does not exist
isDirectory = (dir) ->
  Q.nfcall(fs.stat, dir).then (stat) -> stat.isDirectory()

# Built-in enfield plugins
loadBundledPlugins = ->
  loadPlugins([path.join __dirname, 'plugins'])
    .then (plugins) ->
      bundledPlugins = plugins
      # Copy default filters, but don't overwrite
      for key, filter of tinyliquid.filters
        unless key of bundledPlugins.filters
          bundledPlugins.filters[key] = filter
      return

loadSitePlugins = (config) ->
  # Resolve directories relative to source
  dirs = config.plugins.map (dir) -> path.resolve config.source, dir
  # Only check directories that actually exist
  Q.allSettled(dirs.map (dir) -> Q.nfcall fs.stat, dir)
    .then (results) ->
      pluginDirs = []
      for result, i in results
        continue if result.state isnt 'fulfilled'
        pluginDirs.push dirs[i]

      loadPlugins pluginDirs

loadPlugins = (dirs) ->
  log.verbose "generate", "Looking for plugins in: %s", dirs.join ', '
  Q.all(dirs.map (dir) -> Q.nfcall fs.readdir, dir)
    .then (dirListings) ->
      plugins =
        filters: {}
        tags: {}
        converters: []
        generators: []

      # Make a single list of eligible files
      allFiles = dirListings
        # Resolve Paths
        .map (listing, i) ->
          listing.map (f) -> path.join dirs[i], f
        # Merge lists
        .reduceRight(((prev, listing) -> prev.concat listing), [])
        # Remove non-code files
        .filter (f) ->
          ext = path.extname f
          ext in ['.js','.coffee'] or fs.statSync(f).isDirectory()

      log.silly "generate", "Found plugins %s in %s",
        allFiles.map(path.basename), dirs

      for file in allFiles
        loadFileIntoPlugins file, plugins

      plugins

loadFileIntoPlugins = (file, plugins) ->
  log.verbose "generate", "Loading plugin: %s", file
  plugin = require file

  if 'filters' of plugin
    for key, filter of plugin['filters']
      log.silly "generate", "Found filter for %s", key
      plugins.filters[key] = filter
  if 'tags' of plugin
    for key, tag of plugin['tags']
      log.silly "generate", "Found tag for %s", key
      plugins.tags[key] = tag
  if 'converters' of plugin
    for key, converter of plugin['converters']
      log.silly "generate", "Found converter for %s", key
      plugins.converters.push converter
  if 'generators' of plugin
    for key, generator of plugin['generators']
      log.silly "generate", "Found generator for %s", key
      plugins.generators.push generator
