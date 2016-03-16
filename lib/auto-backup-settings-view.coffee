{View, TextEditorView} = require 'atom-space-pen-views'
module.exports =
class AutoBackupSettingsView extends View
  @content: (self) ->
    @div class: "auto-backup-settings", =>
      @h2 'Restore revision:'
      @div =>
        @subview "revision", new TextEditorView(mini:true, placeholderText: "\"HEAD(default)\" or revision's SHA.")
      @div =>
        @button "Restore", outlet: "restoreBtn", class: "btn", style: "float:right"
        @button "Cancel", outlet: "cancelBtn", class:"btn", style:"float:right"

  initialize: (self) ->
    @self = self
    @cancelBtn.click =>
      @self.hideRestorePanel()
    @restoreBtn.click =>
      @self.restore(@revision.getText())
      @self.hideRestorePanel()
    @revision.on "keyup", (e) =>
      if e.keyCode is 27 # esc
        @self.hideRestorePanel()
      else if e.keyCode is 13 #enter
        @self.restore(@revision.getText())
        @self.hideRestorePanel()
    setTimeout () =>
      @revision.focus()
    , 100
