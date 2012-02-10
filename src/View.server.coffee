{Model} = require 'racer'
uglify = require 'uglify-js'
{escapeHtml} = require './html'
EventDispatcher = require './EventDispatcher'
files = require './files'
module.exports = View = require './View'

isProduction = process.env.NODE_ENV is 'production'

empty = ->
emptyRes =
  getHeader: empty
  setHeader: empty
  write: empty
  end: empty
emptyModel =
  get: empty
  bundle: empty
emptyDom =
  events: new EventDispatcher

escapeInlineScript = (s) -> s.replace /<\//g, '<\\/'

trim = View.trim

# Don't execute before or after functions on the server
View::before = View::after = empty

View::inline = (fn) -> @_inline += uglify("(#{fn})()") + ';'

View::_load = (isStatic, callback) ->
  if isProduction then @_load = (isStatic, callback) -> callback()

  self = this
  appFilename = @_appFilename
  options = @_derbyOptions
  {root, clientName, require} = files.parseName appFilename, options
  @_root = root
  @_clientName = clientName
  @_require = require

  templates = js = null

  if isStatic
    count = 2
    finish = ->
      return if --count
      callback()

  else
    count = 3
    finish = ->
      return if --count
      js = js.replace '"$$templates$$"', JSON.stringify(templates || {})
      files.writeJs js, options, (jsFile) ->
        self._jsFile = jsFile
        callback()

    if @_js
      js = @_js
      finish()

    else files.js appFilename, (value, inline) ->
      js = value
      @_js = value unless isProduction
      self.inline "function(){#{inline}}"  if inline
      finish()

  files.css root, clientName, (value) ->
    self._css = if value then "<style id=$_css>#{trim value}</style>" else ''
    finish()

  files.templates root, clientName, (value) ->
    templates = value
    for name, text of templates
      templates[name] = text = trim text
      self.make name, text
    finish()

View::render = (res = emptyRes, args...) ->
  for arg in args
    if arg instanceof Model
      model = arg
    else if typeof arg is 'object'
      ctx = arg
    else if typeof arg is 'number'
      res.statusCode = arg
    else if typeof arg is 'boolean'
      isStatic = arg
  model = emptyModel  unless model?

  self = this
  # Load templates, css, and scripts from files
  @_load isStatic, ->
    # Wait for transactions to finish and package up the racer model data
    model.bundle (bundle) ->
      self._render res, model, bundle, ctx, isStatic

View::_render = (res, model, bundle, ctx, isStatic) ->
  # Initialize view & model for rendering
  @dom = emptyDom
  model.__events = new EventDispatcher
  model.__blockPaths = {}
  @model = model
  @_idCount = 0

  unless res.getHeader 'content-type'
    res.setHeader 'Content-Type', 'text/html; charset=utf-8'

  # The view.get function renders and sets event listeners. It must be
  # called for all views before the event listeners are retrieved

  # The first chunk includes everything through header. Head should contain
  # any meta tags and script tags, since it is included before CSS.
  # If there is a small amount of header HTML that will display well by itself,
  # it is a good idea to add this to the Header view so that it renders ASAP.
  doctype = @get 'doctype', ctx
  title = escapeHtml @get 'title$s', ctx
  head = @get 'head', ctx
  header = @get 'header', ctx
  res.write "#{doctype}<title>#{title}</title>#{head}#{@_css}#{header}"

  # Remaining HTML
  res.write @get 'body', ctx

  # Inline scripts and external scripts
  clientName = @_clientName
  scripts = "<script>function $(i){return document.getElementById(i)}" +
    escapeInlineScript(@_inline)
  scripts += "function #{clientName}(){#{clientName}=1}"  unless isStatic
  scripts += "</script>" + @get('scripts', ctx)
  scripts += "<script defer async onload=#{clientName}() src=#{@_jsFile}></script>"  unless isStatic
  res.write scripts

  # Initialization script and Tail
  tail = @get 'tail', ctx
  return res.end tail  if isStatic

  res.end "<script>(function(){function f(){setTimeout(function(){" +
    "#{clientName}=require('./#{@_require}')(" + escapeInlineScript(bundle) +
    (if ctx then ',' + escapeInlineScript(JSON.stringify ctx) else '') +
    ")},0)}#{clientName}===1?f():#{clientName}=f})()</script>#{tail}"
