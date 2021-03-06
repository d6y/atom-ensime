net = require('net')
exec = require('child_process').exec
fs = require 'fs'
path = require('path')
_ = require 'lodash'

ensimeClient = require 'ensime-client'


{Subscriber} = require 'emissary'
StatusbarView = require './views/statusbar-view'
{CompositeDisposable} = require 'atom'
{startClient} = require './ensime-startup'

ShowTypes = require './features/show-types'
Implicits = require './features/implicits'
AutoTypecheck = require './features/auto-typecheck'

TypeCheckingFeature = require './features/typechecking'
AutocompletePlusProvider = require './features/autocomplete-plus'
{modalMsg, isScalaSource, projectPath} = require './utils'
{goToTypeAtPoint} = require './features/go-to'
{goToDocIndex, goToDocAtPoint} = require './features/documentation'
ImportSuggestions = require './features/import-suggestions'
Refactorings = require './features/refactorings'

ImplicitInfo = require './model/implicit-info'
ImplicitInfoView = require './views/implicit-info-view'
SelectDotEnsimeView = require './views/select-dot-ensime-view'

{parseDotEnsime, dotEnsimesFilter, allDotEnsimesInPaths} = ensimeClient.dotEnsimeUtils
InstanceManager = ensimeClient.InstanceManager
Instance = ensimeClient.Instance

logapi = require('loglevel')

log = undefined

scalaSourceSelector = """atom-text-editor[data-grammar="source scala"]"""
module.exports = Ensime =

  config: require './config'
    
  addCommandsForStoppedState: ->
    @stoppedCommands = new CompositeDisposable
    @stoppedCommands.add atom.commands.add 'atom-workspace', "ensime:start", => @selectAndBootAnEnsime()

  addCommandsForStartedState: ->
    @startedCommands = new CompositeDisposable
    @startedCommands.add atom.commands.add 'atom-workspace', "ensime:stop", => @selectAndStopAnEnsime()
    @startedCommands.add atom.commands.add 'atom-workspace', "ensime:start", => @selectAndBootAnEnsime()

    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:mark-implicits", => @markImplicits()
    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:unmark-implicits", => @unmarkImplicits()
    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:show-implicits", => @showImplicits()
    @startedCommands.add atom.commands.add 'atom-workspace', "ensime:typecheck-all", => @typecheckAll()
    @startedCommands.add atom.commands.add 'atom-workspace', "ensime:unload-all", => @unloadAll()
    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:typecheck-file", => @typecheckFile()
    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:typecheck-buffer", => @typecheckBuffer()

    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:go-to-definition", => @goToDefinitionOfCursor()

    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:go-to-doc", => @goToDocOfCursor()
    @startedCommands.add atom.commands.add 'atom-workspace', "ensime:browse-doc", => @goToDocIndex()

    @startedCommands.add atom.commands.add scalaSourceSelector, "ensime:format-source", => @formatCurrentSourceFile()

    @startedCommands.add atom.commands.add 'atom-workspace', "ensime:search-public-symbol", => @searchPublicSymbol()
    @startedCommands.add atom.commands.add 'atom-workspace', "ensime:organize-imports", => @organizeImports()



  activate: (state) ->
    logLevel = atom.config.get('Ensime.logLevel')

    logapi.getLogger('ensime.client').setLevel(logLevel)
    logapi.getLogger('ensime.server-update').setLevel(logLevel)
    logapi.getLogger('ensime.startup').setLevel(logLevel)
    logapi.getLogger('ensime.autocomplete-plus-provider').setLevel(logLevel)
    logapi.getLogger('ensime.refactorings').setLevel(logLevel)
    log = logapi.getLogger('ensime.main')
    log.setLevel(logLevel)

    # Install deps if not there
    if(atom.config.get('Ensime.enableAutoInstallOfDependencies'))
      (require 'atom-package-deps').install('Ensime').then ->
        log.trace('Ensime dependencies installed, good to go!')

    @subscriptions = new CompositeDisposable

    # Feature controllers
    @showTypesControllers = new WeakMap
    @implicitControllers = new WeakMap
    @autotypecheckControllers = new WeakMap

    @instanceManager = new InstanceManager

    @addCommandsForStoppedState()
    @someInstanceStarted = false

    @controlSubscription = atom.workspace.observeTextEditors (editor) =>
      if isScalaSource(editor)
        instanceLookup = => @instanceManager.instanceOfFile(editor.getPath())
        clientLookup = -> instanceLookup()?.client
        if atom.config.get('Ensime.enableTypeTooltip')
          if not @showTypesControllers.get(editor) then @showTypesControllers.set(editor, new ShowTypes(editor, clientLookup))
        if not @implicitControllers.get(editor) then @implicitControllers.set(editor, new Implicits(editor, instanceLookup))
        if not @autotypecheckControllers.get(editor) then @autotypecheckControllers.set(editor, new AutoTypecheck(editor, clientLookup))

        @subscriptions.add editor.onDidDestroy () =>
          @deleteControllers editor

    clientLookup = (editor) => @clientOfEditor(editor)
    @autocompletePlusProvider = new AutocompletePlusProvider(clientLookup)
  
    @importSuggestions = new ImportSuggestions()
    @refactorings = new Refactorings

    atom.workspace.onDidStopChangingActivePaneItem (pane) =>
      if(atom.workspace.isTextEditor(pane) and isScalaSource(pane))
        log.trace('this: ' + this)
        log.trace(['@instanceManager: ', @instanceManager])
        instance = @instanceManager.instanceOfFile(pane.getPath())
        @switchToInstance(instance)

  switchToInstance: (instance) ->
    log.trace(['changed from ', @activeInstance, ' to ', instance])
    if(instance != @activeInstance)
      # TODO: create "class" for instance
      @activeInstance?.ui.statusbarView.hide()
      @activeInstance = instance
      if(instance)
        instance.ui.statusbarView.show()


  deactivate: ->
    @instanceManager.destroyAll()

    @subscriptions.dispose()
    @controlSubscription.dispose()

    @autocompletePlusProvider?.dispose()
    @autocompletePlusProvider = null


  clientOfEditor: (editor) ->
    if(editor)
      @instanceManager.instanceOfFile(editor.getPath())?.client
    else
      @instanceManager.firstInstance().client

  clientOfActiveTextEditor: ->
    @clientOfEditor(atom.workspace.getActiveTextEditor())

  # TODO: move out
  statusbarOutput: (statusbarView, typechecking) -> (msg) ->
    typehint = msg.typehint

    if(typehint == 'AnalyzerReadyEvent')
      statusbarView.setText('Analyzer ready!')

    else if(typehint == 'FullTypeCheckCompleteEvent')
      statusbarView.setText('Full typecheck finished!')

    else if(typehint == 'IndexerReadyEvent')
      statusbarView.setText('Indexer ready!')

    else if(typehint == 'CompilerRestartedEvent')
      statusbarView.setText('Compiler restarted!')

    else if(typehint == 'ClearAllScalaNotesEvent')
      typechecking?.clearScalaNotes()

    else if(typehint == 'NewScalaNotesEvent')
      typechecking?.addScalaNotes(msg)

    else if(typehint.startsWith('SendBackgroundMessageEvent'))
      statusbarView.setText(msg.detail)



  startInstance: (dotEnsimePath) ->

    # Register model-view mappings
    @subscriptions.add atom.views.addViewProvider ImplicitInfo, (implicitInfo) ->
      result = new ImplicitInfoView().initialize(implicitInfo)
      result


    # remove start command and add others
    @stoppedCommands.dispose()

    # FIXME: - we have had double commands for each instance :) This is a quick and dirty fix
    if(not @someInstanceStarted)
      @addCommandsForStartedState()
      @someInstanceStarted = true

    dotEnsime = parseDotEnsime(dotEnsimePath)

    typechecking = undefined
    if(@indieLinterRegistry)
      typechecking = TypeCheckingFeature(@indieLinterRegistry.register("Ensime: #{dotEnsimePath}"))

    statusbarView = new StatusbarView()
    statusbarView.init()

    startClient(dotEnsime, @statusbarOutput(statusbarView, typechecking), (client) =>
      atom.notifications.addSuccess("Ensime connected!")
      
      # atom specific ui state of an instance
      ui = {
        statusbarView
        typechecking
        destroy: ->
          statusbarView.destroy()
          typechecking?.destroy()
      }
      instance = new Instance(dotEnsime, client, ui)

      @instanceManager.registerInstance(instance)
      if (not @activeInstance)
        @activeInstance = instance

      client.post({"typehint":"ConnectionInfoReq"}, (msg) -> )

      @switchToInstance(instance)
    )



  deleteControllers: (editor) ->
    deactivateAndDelete = (controller) ->
      controller.get(editor)?.deactivate()
      controller.delete(editor)

    deactivateAndDelete(@showTypesControllers)
    deactivateAndDelete(@implicitControllers)
    deactivateAndDelete(@autotypecheckControllers)


  deleteAllEditorsControllers: ->
    for editor in atom.workspace.getTextEditors()
      @deleteControllers editor

  # Shows dialog to select a .ensime under this project paths and calls callback with parsed
  selectDotEnsime: (callback, filter = -> true) ->
    dirs = atom.project.getPaths()
  
    allDotEnsimesInPaths(dirs).then (dotEnsimes) ->
      filteredDotEnsime = _.filter(dotEnsimes, filter)

      if(filteredDotEnsime.length == 0)
        modalMsg("No .ensime file found. Please generate with `sbt gen-ensime` or similar")
      else if (filteredDotEnsime.length == 1)
        callback(filteredDotEnsime[0])
      else
        new SelectDotEnsimeView(filteredDotEnsime, (selectedDotEnsime) ->
          callback(selectedDotEnsime)
        )

  selectAndBootAnEnsime: ->
    @selectDotEnsime(
      (selectedDotEnsime) => @startInstance(selectedDotEnsime.path),
      (dotEnsime) => not @instanceManager.isStarted(dotEnsime.path)
    )


  selectAndStopAnEnsime: ->
    stopDotEnsime = (selectedDotEnsime) =>
      dotEnsime = parseDotEnsime(selectedDotEnsime.path)
      @instanceManager.stopInstance(dotEnsime)
      @switchToInstance(undefined)

    @selectDotEnsime(stopDotEnsime, (dotEnsime) => @instanceManager.isStarted(dotEnsime.path))

  typecheckAll: ->
    @clientOfActiveTextEditor()?.post( {"typehint": "TypecheckAllReq"}, (msg) ->)

  unloadAll: ->
    @clientOfActiveTextEditor()?.post( {"typehint": "UnloadAllReq"}, (msg) ->)

  # typechecks currently open file
  typecheckBuffer: ->
    b = atom.workspace.getActiveTextEditor()?.getBuffer()
    @clientOfEditor(b)?.typecheckBuffer(b.getPath(), b.getText())

  typecheckFile: ->
    b = atom.workspace.getActiveTextEditor()?.getBuffer()
    @clientOfEditor(b)?.typecheckFile(b.getPath())

  goToDocOfCursor: ->
    editor = atom.workspace.getActiveTextEditor()
    goToDocAtPoint(@clientOfEditor(editor), editor)

  goToDocIndex: ->
    editor = atom.workspace.getActiveTextEditor()
    goToDocIndex(@clientOfEditor(editor))

  goToDefinitionOfCursor: ->
    editor = atom.workspace.getActiveTextEditor()
    textBuffer = editor.getBuffer()
    pos = editor.getCursorBufferPosition()
    goToTypeAtPoint(@clientOfEditor(editor), textBuffer, pos)

  markImplicits: ->
    editor = atom.workspace.getActiveTextEditor()
    @implicitControllers.get(editor)?.showImplicits()

  unmarkImplicits: ->
    editor = atom.workspace.getActiveTextEditor()
    @implicitControllers.get(editor)?.clearMarkers()

  showImplicits: ->
    editor = atom.workspace.getActiveTextEditor()
    @implicitControllers.get(editor)?.showImplicitsAtCursor()


  provideAutocomplete: ->
    log.trace('provideAutocomplete called')

    getProvider = =>
      @autocompletePlusProvider

    {
      selector: '.source.scala'
      disableForSelector: '.source.scala .comment'
      inclusionPriority: 10
      excludeLowerPriority: true

      getSuggestions: ({editor, bufferPosition, scopeDescriptor, prefix}) ->
        provider = getProvider()
        if(provider)
          new Promise (resolve) ->
            log.trace('ensime.getSuggestions')
            provider.getCompletions(editor.getBuffer(), bufferPosition, resolve)
        else
          []

      onDidInsertSuggestion: (x) ->
        provider = getProvider()
        provider.onDidInsertSuggestion x
    }

  provideHyperclick: ->
    {
      providerName: 'ensime-atom'
      getSuggestionForWord: (textEditor, text, range) =>
        if isScalaSource(textEditor)
          client = @clientOfEditor(textEditor)
          {
            range: range
            callback: () ->
              if(client)
                goToTypeAtPoint(client, textEditor.getBuffer(), range.start)
              else
                atom.notifications.addError("Ensime not started! :(", {
                  dismissable: true
                  detail: "There is no running ensime instance for this particular file. Please start ensime first!"
                  })
          }
        else
          undefined

    }

  # Just add registry to delegate registration on instances
  consumeLinter: (@indieLinterRegistry) ->


  provideIntentions: ->
    getIntentions = (req) =>
      textEditor = req.textEditor
      bufferPosition = req.bufferPosition
      
      new Promise (resolve) =>
        @importSuggestions.getImportSuggestions(
          @clientOfEditor(textEditor),
          textEditor.getBuffer(),
          textEditor.getBuffer().characterIndexForPosition(bufferPosition),
          textEditor.getWordUnderCursor(), # FIXME!
          (res) =>
            resolve(_.map(res.symLists[0], (sym) =>
              onSelected = => @refactorings.doImport(@clientOfEditor(textEditor), sym.name, textEditor.getPath(), textEditor.getBuffer())
              {
                priority: 100
                icon: 'bucket'
                class: 'custom-icon-class'
                title: "import #{sym.name}"
                selected: onSelected
              }
            ))
          )
    {
      grammarScopes: ['source.scala']
      getIntentions: getIntentions
    }

  formatCurrentSourceFile: ->
    editor = atom.workspace.getActiveTextEditor()
    cursorPos = editor.getCursorBufferPosition()
    callback = (msg) ->
      editor.setText(msg.text)
      editor.setCursorBufferPosition(cursorPos)
    @clientOfEditor(editor)?.formatSourceFile(editor.getPath(), editor.getText(), callback)


  searchPublicSymbol: ->
    unless @publicSymbolSearch
      PublicSymbolSearch = require('./features/public-symbol-search')
      @publicSymbolSearch = new PublicSymbolSearch()
    @publicSymbolSearch.toggle(@clientOfActiveTextEditor())

  organizeImports: ->
    editor = atom.workspace.getActiveTextEditor()
    @refactorings.organizeImports(@clientOfEditor(editor), editor.getPath())
