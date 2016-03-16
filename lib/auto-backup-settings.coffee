{CompositeDisposable, Disposable} = require 'atom'
path = require "path"
fs = require "fs"
_ = require "underscore-plus"
http = require "https"
CSON = require "cson"

module.exports = AutoBackupSettings =

  inChanges: false

  config:
    gistId:
      type: "string"
      default: ""
    accessToken:
      type: "string"
      default: ""
    isPackageListBackup:
      description: "Require restart for Atom."
      type: "boolean"
      default: true
    backupFiles:
      description: "Require restart for Atom."
      type: "array"
      default: [
        "config.cson",
        "init.coffee",
        "styles.less",
        "keymap.cson",
        "snippets.cson",
      ]
      items:
        type: "string"
    ignorePath:
      description: "Ignore path in config.cson. type: 'array'"
      type: "array"
      default: ["*.exception-reporting.userId", "*.core.projectHome"]

  subscriptions: null

  activate: (state) ->
    @subscriptions = new CompositeDisposable
    @name = "auto-backup-settings"

    @subscriptions.add atom.commands.add 'atom-workspace', "auto-backup-settings:backup": => @backup()
    @subscriptions.add atom.commands.add 'atom-workspace', "auto-backup-settings:restore": => @showRestorePanel()

    @configPath = path.dirname atom.config.getUserConfigPath()
    @configs = atom.config.get "#{@name}.backupFiles"
    @isPackageListBackup = atom.config.get "#{@name}.isPackageListBackup"

    @github = {
      hostname: "api.github.com",
      headers: {
        "User-Agent": "Atom #{@name}",
      },
    }

    debounced = _.debounce(() =>
      @backup()
    , 1000)
    for config in @configs
      filePath = path.join(@configPath, config)
      fs.watch filePath, () =>
        debounced() unless @inChanges
    atom.packages.onDidLoadPackage (p) =>
      debounced() unless @inChanges
    atom.packages.onDidUnloadPackage () =>
      debounced() unless @inChanges

  showRestorePanel: ->
    AutoBackupSettingsView = require "./auto-backup-settings-view"
    view = new AutoBackupSettingsView(this)
    @modalPanel = atom.workspace.addModalPanel(item: atom.views.getView(view))

  hideRestorePanel: ->
    workspaceElement = atom.views.getView(atom.workspace)
    workspaceElement.focus()
    @modalPanel.hide()

  deactivate: ->
    @subscriptions.dispose()
    @modalPanel = null

  checkCache: ->
    isChange = false
    json = localStorage.getItem("#{@name}.cache")
    if json?
      @cache = JSON.parse json
    else
      isChange = true
    return isChange

  checkConfigs: ->
    isChange = false
    @digests = {}
    @files = {}
    for config in @configs
      file = path.join(@configPath, config)
      text = fs.readFileSync file, "utf-8"

      if config is "config.cson"
        json = CSON.parse text
        for item in atom.config.get("#{@name}.ignorePath")
          obj = json
          for val, i in item.split(".")
            if i is item.split(".").length - 1
              delete obj[val] if obj?[val]
            else
              obj = obj[val] if obj?
        text = CSON.createCSONString json, {indent: "  "}

      @files[config] = { content: text }
      digest = @getHash(text)
      @digests[file] = digest

    for key of @cache
      file = key.replace(@configPath, "").replace(path.sep, "")
      continue if file is "packages.json"
      if @configs.indexOf(file) is -1
        console.log "#{key} is changed."
        @files[file] = null
        isChange = true
    return isChange

  checkPackages: ->
    isChange = false
    if @isPackageListBackup?
        packages = @getPackages()
        @digests["packages.json"] = @getHash(packages)
        @files["packages.json"] = {content: packages}
    else
      if @cache["packages.json"]?
        console.log "packages.json is changed."
        @files["packages.json"] = null
        isChange = true
    return isChange

  backup: ()->
    access_token = atom.config.get("#{@name}.accessToken")
    gistId = atom.config.get("#{@name}.gistId")
    return null unless access_token? and gistId?
    isChange = false
    isChange = true if @checkCache()
    isChange = true if @checkConfigs()
    isChange = true if @checkPackages()

    unless isChange
      for key, value of @digests
        if @cache[key] isnt value
          console.log "#{key} is changed."
          isChange = true
          break
    @patchGist() if isChange

  getPackages: ->
    items = []
    packages = atom.packages.getLoadedPackages()
    for p in packages
      item = {
        name: p.name,
        version: p.metadata.version
        is_disabled: atom.packages.isPackageDisabled(p.name)
      }
      item.theme = p.metadata.theme if p.metadata.theme?
      items.push item
    return JSON.stringify items, null, 4

  restore: (sha)->
    @inChanges = true
    sha = "HEAD" if sha is ""
    @getGist sha, (res) =>
      files = res.files
      console.log "Restore for rev:#{sha}"
      for key, value of files
        if @configs.indexOf(key) > -1
          @restoreFile key, value.content
          console.log "\"#{key}\" restored."
        else if key is "packages.json"
          @restorePackage value.content
          console.log "packages restored."
      console.log "Restored all done."
      @inChanges = false

  notify: (level, message) ->
    n = atom.notifications
    message = "Auto-backup-settings: #{message}"
    switch level
      when "success"
        n.addSuccess message
      when "info"
        n.addInfo message
      when "warning"
        n.addWarning message, dismissable: true
        console.warn message
      when "error"
        n.addError message, dismissable: true
        console.error message

  restoreFile: (config, content) ->
    file = path.join(@configPath, config)
    fs.writeFile file, content, "utf8", (err) =>
      @notify "error", "Error: #{err}" if err

  restorePackage: (packages) ->
    restore = JSON.parse packages
    installed = JSON.parse @getPackages()
    for p in installed
      continue unless p.name?
      unless atom.packages.isPackageDisabled(p.name)  # if package is enabled
        for r in restore
          if p.name is r.name and atom.packages.isPackageDisabled(r.name)
            atom.packages.disablePackage(p.name)
            continue

    for p in restore
      unless atom.packages.resolvePackagePath(p.name)
        @notify "warning", "\"#{p.name}\" is not installed."
        continue
      if p.is_disabled is true
        unless atom.packages.isPackageDisabled(p.name)
          atom.packages.disablePackage(p.name)
      else
        if atom.packages.isPackageDisabled(p.name)
          atom.packages.enablePackage(p.name)

  getGist: (sha, cb) ->
    id = "#{@getGistId()}"
    id = id + "/#{sha}" if sha isnt "HEAD"

    options = @github
    options.method = "GET"
    options.path = "/gists/#{id}?token=#{@getAccessToken()}"
    req = http.request options, (res) =>
      body = ""
      res.setEncoding("utf8")
      res.on "data", (chunk) =>
        body += chunk
      res.on "end", () =>
        if res.statusCode is 200
          cb(JSON.parse(body))
          @notify "success", "restore was success."
        else
          @notify "error", "Error: #{res.statusCode} #{body}"
    req.on "error", (err) =>
      @notify "error", "Error: #{err}"
    req.end()

  getGistId: ->
    return atom.config.get "#{@name}.gistId"

  getAccessToken: ->
    return atom.config.get "#{@name}.accessToken"

  patchGist: () ->
    files = @files
    files["_AutoBackupSettings.md"] = { content: "This gist was created by #{@name}.  \nSee http://atom.io/nobuhito/#{@name}" }

    json = {
      description: "automatic update by #{@name}",
      files: files,
    }

    options = @github
    options.method = "PATCH"
    options.path = "/gists/#{@getGistId()}?access_token=#{@getAccessToken()}"
    options.headers["Content-Type"] = "application/json"
    req = http.request options, (res) =>
      body = ""
      res.setEncoding("utf8")
      res.on "data", (chunk) =>
        body += chunk
      res.on "end", () =>
        if res.statusCode is 200
          localStorage.setItem("#{@name}.cache", JSON.stringify(@digests))
          @notify "success", "backup was success."
        else
          @notify "error", "Error: #{res.statusCode} #{body}"
    req.on "error", (err) =>
      @notify "error", "Error: #{err}"
    req.write(JSON.stringify(json))
    req.end()

  getHash: (text) ->
    return require("crypto").createHash("sha1").update(text).digest("hex")
