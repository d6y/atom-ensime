# Download and startup of ensime server
fs = require('fs')
path = require('path')
{exec, spawn} = require('child_process')
{log, modalMsg, projectPath, packageDir,
 withSbt, mkClasspathFileName} = require('./utils')
EnsimeServerUpdateLogView = require('./views/ensime-server-update-log-view')
lisp = require './ensime-client/lisp/lisp'
{sexpToJObject} = require './ensime-client/lisp/swank-extras'
remote = require 'remote'
{parseDotEnsime} = require './ensime-client/dotensime-utils'
Client = require './client'
{updateEnsimeServer} = require './ensime-server-update'
_ = require 'lodash'

chokidar = require 'chokidar'

###
## Pseudo:
This code is pretty complex with lots of continuation passing.
Here is some kind of pseudo for easier understanding:

startClient(dotEnsime) ->
  if(serverRunning(dotEnsime))
    doStartClient(dotEnsime)
  else
    startServer(dotEnsime, () ->
      doStartClient(dotEnsime)
    )

startServer(dotEnsime, whenStarted) ->
  if(classpathOk(dotEnsime))
    doStartServer(dotEnsime, whenStarted)
  else
    updateServer(dotEnsime, () ->
      doStartServer(dotEnsime, whenStarted)
    )

###

# ensime server version from settings
ensimeServerVersion = ->
  atom.config.get('Ensime.ensimeServerVersion')



# Check that we have a classpath that is newer than atom
# ensime package.json (updated on release), otherwise delete it
classpathFileOk = (cpF) ->
  if not fs.existsSync(cpF)
    false
  else
    cpFStats = fs.statSync(cpF)
    fine = cpFStats.isFile && cpFStats.ctime > fs.statSync(packageDir() + path.sep + 'package.json').mtime
    if not fine
      fs.unlinkSync(cpF)
    fine

mkPortFilePath = (cacheDir) -> cacheDir + path.sep + "port"

mkHttpPortFilePath = (cacheDir) -> cacheDir + path.sep + "http"

mkServerLogFilePath = (cacheDir) -> cacheDir + path.sep + 'server.log'

removeTrainingNewline = (str) -> str.replace(/^\s+|\s+$/g, '')

# Start an ensime client given path to .ensime. If server already running, just use, else startup that too.
startClient = (parsedDotEnsime, generalHandler, callback) ->
  portFilePath = mkPortFilePath(parsedDotEnsime.cacheDir)
  httpPortFilePath = mkHttpPortFilePath(parsedDotEnsime.cacheDir)

  log = console.log.bind(console)

  if fs.existsSync(portFilePath) && fs.existsSync(mkHttpPortFilePath)
    # server running, no need to start
    port = fs.readFileSync(portFilePath).toString()
    httpPort = removeTrainingNewline(fs.readFileSync(httpPortFilePath).toString())
    callback(new Client(port, httpPort, generalHandler))
  else
    serverPid = undefined

    whenAllAdded = (dir, files, f) ->
      log('starting watching for: '+files)
      seen = 0
      watcher = chokidar.watch(dir, {
        persistent: true
      }).on('add', (path) ->
        if _.some(files, (f) -> f == path)
          seen = seen + 1
        console.log 'Seen: ', seen, ' file: ', path
        if files.length == seen
          watcher.close()
          console.log('All files seen. Starting client')
          f()
      )

    whenAllAdded(parsedDotEnsime.cacheDir, [portFilePath, httpPortFilePath], () ->
      port = fs.readFileSync(portFilePath).toString()
      httpPort = removeTrainingNewline(fs.readFileSync(httpPortFilePath).toString())
      callback(new Client(port, httpPort, generalHandler, serverPid))
    )

    # no server running, start that first
    startEnsimeServer(parsedDotEnsime, (pid) -> serverPid = pid)


# Start ensime server. If classpath file is out of date, make an update first
startEnsimeServer = (parsedDotEnsime, pidCallback) ->
  if not fs.existsSync(parsedDotEnsime.cacheDir)
    fs.mkdirSync(parsedDotEnsime.cacheDir)

  cpF = mkClasspathFileName(parsedDotEnsime.scalaVersion, ensimeServerVersion())
  log("classpathfile name: #{cpF}")

  if(not classpathFileOk(cpF))
    # update server and start
    withSbt (sbtCmd) ->
      updateEnsimeServer(sbtCmd, parsedDotEnsime.scalaVersion, ensimeServerVersion(), () -> doStartEnsimeServer(parsedDotEnsime, pidCallback))
  else
    # just start server
    doStartEnsimeServer(parsedDotEnsime, pidCallback)

# Start ensime server when classpath is up to date
doStartEnsimeServer = (parsedDotEnsime, pidCallback) ->
  cpF = mkClasspathFileName(parsedDotEnsime.scalaVersion, ensimeServerVersion())
  toolsJar = "#{parsedDotEnsime.javaHome}#{path.sep}lib#{path.sep}tools.jar"
  classpath = toolsJar + path.delimiter + fs.readFileSync(cpF, {encoding: 'utf8'})
  javaCmd = "#{parsedDotEnsime.javaHome}#{path.sep}bin#{path.sep}java"
  ensimeServerFlags = "#{atom.config.get('Ensime.ensimeServerFlags')}"
  args = ["-classpath", "#{classpath}", "-Densime.config=#{parsedDotEnsime.dotEnsimePath}", "-Densime.protocol=jerk"]
  if ensimeServerFlags.length > 0
    args.push ensimeServerFlags  ## Weird, but extra " " broke everyting

  args.push "org.ensime.server.Server"

  log("Starting ensime server with: #{javaCmd} #{args.join(' ')}")

  serverLog = fs.createWriteStream(mkServerLogFilePath(parsedDotEnsime.cacheDir))

  pid = spawn(javaCmd, args, {
    detached: atom.config.get('Ensime.runServerDetached')
  })
  pid.stdout.pipe(serverLog) # TODO: have a screenbuffer tail -f this file.
  pid.stderr.pipe(serverLog)
  pid.stdin.end()
  pidCallback(pid)


module.exports = {
  startClient
}
