## This is the SCGI Website and the hub.
import sockets, json, strutils, os, scgi, strtabs, times, streams, parsecfg
import types, db

const
  websiteURL = "http://dom96.co.cc/nimbuild/"

type
  HPlatformStatus = seq[tuple[platform: string, status: TStatus]]
  
  TState = object
    sock: TSocket ## Hub server socket. All modules connect to this.
    modules: seq[TModule]
    scgi: TScgiState
    database: TDb
    platforms: HPlatformStatus
    password: string ## The password that foreign modules need to be accepted.
    bindAddr: string
    bindPort: int
    scgiPort: int
    redisPort: int

  TModule = object
    name: string
    sock: TSocket ## Client socket
    connected: bool
    platform: string
    lastPong: float
    pinged: bool # whether we are waiting for a pong from the module.
    ping: float # in seconds
    ip: string # IP address this module is connecting from

proc parseConfig(state: var TState, path: string) =
  var f = newFileStream(path, fmRead)
  if f != nil:
    var p: TCfgParser
    open(p, f, path)
    var count = 0
    while True:
      var n = next(p)
      case n.kind
      of cfgEof:
        break
      of cfgSectionStart:
        raise newException(EInvalidValue, "Unknown section: " & n.section)
      of cfgKeyValuePair, cfgOption:
        case normalize(n.key)
        of "bindaddr":
          state.bindAddr = n.value
          inc(count)
        of "bindport":
          state.bindPort = parseInt(n.value)
          inc(count)
        of "scgiport":
          state.scgiPort = parseInt(n.value)
          inc(count)
        of "redisport":
          state.redisPort = parseInt(n.value)
          inc(count)
        of "password":
          state.password = n.value
          inc(count)
      of cfgError:
        raise newException(EInvalidValue, "Configuration parse error: " & n.msg)
    if count < 5:
      quit("Not all settings have been specified in the .ini file", quitFailure)
    close(p)
  else:
    quit("Cannot open configuration file: " & path, quitFailure)

proc open(configPath: string): TState =
  parseConfig(result, configPath)

  result.sock = socket()
  if result.sock == InvalidSocket: OSError()
  result.sock.bindAddr(TPort(result.bindPort), result.bindAddr)
  result.sock.listen()
  result.modules = @[]
  result.platforms = @[]
  
  # Open scgi instance
  result.scgi.open(TPort(result.scgiPort))
  
  # Connect to the database
  try:
    result.database = db.open("localhost", TPort(result.redisPort))
  except EOS:
    quit("Couldn't connect to redis: " & OSErrorMsg())

# Modules
proc populateReadSocks(state: var TState): seq[TSocket] =
  result = @[]
  for i in items(state.modules):
    result.add(i.sock)
  result.add(state.sock)

proc contains(modules: seq[TModule], name: string): bool =
  for i in items(modules):
    if i.name == name: return true
  
  return false

proc contains(platforms: HPlatformStatus,
              p: string): bool =
  for platform, s in items(platforms):
    if platform == p:
      return True

proc parseGreeting(state: var TState, client: var TSocket,
                   IPAddr: string, line: string): bool =
  # { "name": "modulename" }
  var json = parseJson(line)
  if IPAddr != "127.0.0.1":
    # Check for password
    var fail = true
    if json.existsKey("pass"):
      if json["pass"].str == state.password:
        fail = false
      else:
        echo("Got incorrect password: ", json["pass"].str)

    if fail: return false

  var module: TModule
  module.name = json["name"].str
  module.sock = client
  module.platform = json["platform"].str
  module.ip = IPAddr
  module.lastPong = epochTime()
  module.pinged = false
  echo(module.name, " connected from ", IPAddr)
  
  # Only add this module platform to platforms if it's a `builder`, and
  # if platform doesn't already exist.
  if module.name == "builder":
    if module.platform notin state.platforms:
      state.platforms.add((module.platform, initStatus()))
    else:
      echo("Platform(", module.platform, ") already exists.")
      return False

  state.modules.add(module)
  return True

proc `[]`*(ps: HPlatformStatus,
           platform: string): TStatus =
  assert(ps.len > 0)
  for p, s in items(ps):
    if p == platform:
      return s
  raise newException(EInvalidValue, platform & " is not a valid platform.")

proc `[]=`*(ps: var HPlatformStatus,
            platform: string, status: TStatus) =
  var index = -1
  var count = 0
  for p, s in items(ps):
    if p == platform:
      index = count
      break
    inc(count)

  if index != -1:
    ps.del(index)
  else:
    raise newException(EInvalidValue, platform & " is not a valid platform.")
  
  ps.add((platform, status))

proc uniqueMName(module: TModule): string =
  result = ""
  result.add module.name
  result.add "-"
  result.add module.platform
  result.add "(" & module.ip & ")"

proc remove(state: var TState, module: TModule) =
  for i in 0..len(state.modules):
    var m = state.modules[i]
    if m.name == module.name and
       m.platform == module.platform and 
       m.ip == module.ip:
      state.modules[i].sock.close()
      echo(uniqueMName(state.modules[i]), " disconnected.")

      # if module is a builder remove it from platforms.
      if state.modules[i].name == "builder":
        for p in 0..len(state.platforms):
          if state.platforms[p].platform == state.modules[i].platform:
            state.platforms.delete(p)
            break
      
      state.modules.delete(i)
      return

proc setStatus(state: var TState, p: string, status: TStatusEnum,
               desc, hash: string) =
  var s = state.platforms[p]
  s.status = status
  s.desc = desc
  s.hash = hash
  echo("setStatus -- ", TStatusEnum(status), " -- ", p)
  state.platforms[p] = s

# TODO: Instead of using assertions provide a function which checks whether the
# key exists and throw an exception if it doesn't.

proc parseMessage(state: var TState, mIndex: int, line: string) =
  var json = parseJson(line)
  var m = state.modules[mIndex]
  if json.existsKey("status"):
    # { "status": -1, desc: "...", platform: "...", hash: "123456" }
    assert(json.existsKey("hash"))
    var hash = json["hash"].str

    # TODO: Clean this up?
    case TStatusEnum(json["status"].num)
    of sBuildFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildFailure, json["desc"].str, hash)
      state.database.updateProperty(hash, m.platform, "buildResult",
                                    $int(bFail))
      state.database.updateProperty(hash, m.platform, "failReason",
                                    json["desc"].str)
      # This implies that the tests failed too. If we leave this as unknown,
      # the website will show the 'progress.gif' image, which we don't want.
      state.database.updateProperty(hash, m.platform,
          "testResult", $int(tFail))
    of sBuildInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildInProgress, json["desc"].str, hash)
    of sBuildSuccess:
      state.setStatus(m.platform, sBuildSuccess, "", hash)
      state.database.updateProperty(hash, m.platform, "buildResult",
                                    $int(bSuccess))
    of sTestFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sTestFailure, json["desc"].str, hash)
      
      state.database.updateProperty(hash, m.platform,
          "testResult", $int(tFail))
      state.database.updateProperty(hash, m.platform,
          "failReason", state.platforms[m.platform].desc)
    of sTestInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sTestInProgress, json["desc"].str, hash)
    of sTestSuccess:
      assert(json.existsKey("total"))
      assert(json.existsKey("passed"))
      assert(json.existsKey("skipped"))
      assert(json.existsKey("failed"))
      state.setStatus(m.platform, sTestSuccess, "", hash)
      state.database.updateProperty(hash, m.platform,
          "testResult", $int(tSuccess))
      state.database.updateProperty(hash, m.platform,
          "total", json["total"].str)
      state.database.updateProperty(hash, m.platform,
          "passed", json["passed"].str)
      state.database.updateProperty(hash, m.platform,
          "skipped", json["skipped"].str)
      state.database.updateProperty(hash, m.platform,
          "failed", json["failed"].str)
    of sDocGenFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sDocGenFailure, json["desc"].str, hash)
    of sDocGenInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sDocGenInProgress, json["desc"].str, hash)
    of sDocGenSuccess:
      state.setStatus(m.platform, sDocGenSuccess, "", hash)
    of sCSrcGenFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sCSrcGenFailure, json["desc"].str, hash)
    of sCSrcGenInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sCSrcGenInProgress, json["desc"].str, hash)
    of sCSrcGenSuccess:
      state.setStatus(m.platform, sCSrcGenSuccess, "", hash)
      state.database.updateProperty(hash, m.platform, "csources", "t")
    of sUnknown:
      assert(false)
  elif json.existsKey("payload"):
    # { "payload": { .. } }
    # Check if the commit exists.
    if not state.database.commitExists(json["payload"]["after"].str):
      # Make sure this is the master branch.
      if json["payload"]["ref"].str == "refs/heads/master":
        var commits = json["payload"]["commits"]
        var latestCommit = commits[commits.len-1]
        # Add commit to database
        state.database.addCommit(json["payload"]["after"].str,
            latestCommit["message"].str,
            latestCommit["author"]["username"].str)

        # Send this message to the "builder" modules
        for module in items(state.modules):
          if module.name == "builder":
            state.database.addPlatform(json["payload"]["after"].str,
                module.platform)
           
            # Add "rebuild" flag.
            json["rebuild"] = newJBool(false)
               
            module.sock.send($json & "\c\L")
      else:
        echo("Not master branch, not rebuilding. Got: ",
             json["payload"]["ref"].str)
              
      # Send this message to the "irc" module.
      if "irc" in state.modules:
        for module in items(state.modules):
          if module.name == "irc":
            module.sock.send($json & "\c\L")
    else:
      echo("Commit already exists. Not rebuilding.")

  elif json.existsKey("rebuild"):
    # { "rebuild": "hash" }
    var hash = json["rebuild"].str
    var reply = newJObject()
    if state.database.commitExists(hash, true):
      # You can only rebuild the newest commit. (For now, TODO?)
      var fullHash = state.database.expandHash(hash)
      if state.database.isNewest(hash):
        var success = false
        for module in items(state.modules):
          if module.name == "builder":
            var jobj = newJObject()
            jobj["payload"] = newJObject()
            jobj["payload"]["after"] = newJString(fullHash)
            jobj["rebuild"] = newJBool(true)
           
            if not state.database.platformExists(fullHash, module.platform):
              state.database.addPlatform(fullHash, module.platform)
            
            module.sock.send($jobj & "\c\L")
            success = true
        
        if success:
          reply["success"] = newJNull()
        else:
          reply["fail"] = newJString("No builders available.")
      else:
        reply["fail"] = newJString("Given commit is not newest.")
    else:
      reply["fail"] = newJString("Commit could not be found")
    
    m.sock.send($reply & "\c\L")

  elif json.existsKey("latestCommit"):
    var commit = state.database.getNewest()
    var reply = newJObject()
    reply["payload"] = newJObject()
    reply["payload"]["after"] = newJString(commit)
    reply["rebuild"] = newJBool(true)
    m.sock.send($reply & "\c\L")
    if not state.database.platformExists(commit, m.platform):
      state.database.addPlatform(commit, m.platform)

  elif json.existsKey("pong"):
    # Module received PING and replied with PONG.
    state.modules[mIndex].pinged = false
    state.modules[mIndex].ping = epochTime() - json["pong"].str.parseFloat()
    state.modules[mIndex].lastPong = epochTime()

  else:
    echo("[Fatal] Can't understand message from " & m.name & ": ",
         line)
    assert(false)
      
proc handleModuleMsg(state: var TState, readSocks: seq[TSocket]) =
  var disconnect: seq[TModule] = @[] # Modules which disconnected
  for i in 0..state.modules.len()-1:
    var m = state.modules[i]
    if m.sock notin readSocks:
      var line = ""
      if recvLine(m.sock, line):
        echo("Got line from $1: $2" % [m.name, line])

        # Getting a message is a sign of the module still being alive.
        state.modules[i].lastPong = epochTime()

        state.parseMessage(i, line)
      else:
        # Assume the module disconnected
        disconnect.add(m)
  
  # Remove disconnected modules
  for m in items(disconnect):
    state.remove(m)

proc handlePings(state: var TState) =
  var remove: seq[TModule] = @[] # Modules that have timed out.
  for i in 0..state.modules.len-1:
    var module = state.modules[i]
    if module.name == "builder":
      if (epochTime() - module.lastPong) >= 100.0:
        var obj = newJObject()
        obj["ping"] = newJString(formatFloat(epochTime()))
        module.sock.send($obj & "\c\L")
        module.lastPong = epochTime() # This is a bit misleading, but I don't
                                      # want to add lastPing
        module.pinged = true
        echo("Pinging ", uniqueMName(module))
    
      if module.pinged and (epochTime() - module.lastPong) >= 25.0:
        echo(uniqueMName(module),
             " has not replied to PING. Assuming timeout!!!")
        remove.add(module)

  # Remove the modules that have timed out.
  for m in items(remove):
    state.remove(m)

# HTML Generation

proc joinUrl(u, u2: string): string =
  if u.endswith("/"):
    return u & u2
  else: return u & "/" & u2

proc getUrl(c: TCommit, p: TPlatform): tuple[weburl, logurl: string] =
  var weburl = joinUrl(websiteUrl, "commits/$2/$1/" %
                                     [c.hash[0..11], p.platform])
  var logurl = joinUrl(weburl, "log.txt")
  return (weburl, logurl)

proc genCssPath(state: TState): string =
  var reqPath = state.scgi.headers["REQUEST_URI"]
  if reqPath.endswith("/"):
    return ""
  else: return reqPath & "/"

proc genPlatformResult(c: TCommit, p: TPlatform, platforms: HPlatformStatus,
                       cssPath: string): string =
  result = ""
  case p.buildResult
  of bUnknown:
    # Check whether this platform is currently building this commit.
    if p.platform in platforms:
      if platforms[p.platform].hash == c.hash:
        result.add("<img src=\"$1static/images/progress.gif\"/>" % [cssPath])
  of bFail:
    var (weburl, logurl) = getUrl(c, p)
    result.add("<a href=\"$1\" class=\"fail\">fail</a>" % [logurl])
  of bSuccess: result.add("ok")
  result.add(" ")
  case p.testResult
  of tUnknown:
    if p.platform in platforms:
      if platforms[p.platform].hash == c.hash:
        result.add("<img src=\"$1static/images/progress.gif\"/>" %
                 [cssPath])
  of tFail:
    var (weburl, logurl) = getUrl(c, p)
    result.add("<a href=\"$1\" class=\"fail\">fail</a>" % [logurl])
  of tSuccess:
    var (weburl, logurl) = getUrl(c, p)
    var testresultsURL = joinUrl(weburl, "testresults.html")
    var percentage = float(p.passed) / float(p.total - p.skipped) * 100.0
    result.add("<a href=\"$1\" class=\"success\">" % [testresultsURL] &
               formatFloat(percentage, precision=4) & "%</a>")

proc genDownloadButtons(entries: seq[TEntry],
                        platforms: seq[string]): string =
  result = ""
  const 
    downloadSpan = "<span class=\"download\"></span>"
    docSpan      = "<span class=\"book\"></span>"
  var i = 0
  var cSrcs = False
  
  for p in items(platforms):
    for c, pls in items(entries):
      if p in pls:
        var platform = pls[p]
        if platform.buildResult == bSuccess:
          var url = joinUrl(websiteUrl, "commits/$2/$1/nimrod_$1.zip" %
                            [c.hash[0..11], platform.platform])
          var class = ""
          if i == 0: class = "left button"
          else: class = "middle button"
          
          result.add("<a href=\"$1\" class=\"$2\">$3$4</a>" %
                     [url, class, downloadSpan,
                      platform.platform & "-" & c.hash[0..11]])
                      
          if platform.csources and not cSrcs:
            var cSrcUrl = joinUrl(websiteUrl,
                                  "commits/$2/$1/nimrod_$1_csources.zip" %
                                  [c.hash[0..11], platform.platform])
            result.add("<a href=\"$1\" class=\"$2\">$3$4</a>" %
                       [cSrcUrl, "middle button", downloadSpan,
                        "csources-" & c.hash[0..11]])
          break
        inc(i)
  
  result.add("<a href=\"$1\" class=\"$2\">$3Documentation</a>" %
             [joinUrl(websiteURL, "docs/lib.html"), "right active button",
              docSpan])

include "index.html"
# SCGI

proc safeSend(client: TSocket, data: string) =
  try:
    client.send(data)
  except EOS:
    echo("[Warning] Got error from send(): ", OSErrorMsg())

proc handleRequest(state: var TState) =
  var client = state.scgi.client
  var headers = state.scgi.headers
  echo(headers["HTTP_USER_AGENT"])
  echo(headers)
  if headers["REQUEST_METHOD"] == "GET":
    var hostname = ""
    try:
      hostname = gethostbyaddr(headers["REMOTE_ADDR"]).name
    except EOS:
      hostname = getCurrentExceptionMsg()
    echo("Got website request from: ", hostname)
    var html = state.genHtml()
    client.safeSend("Status: 200 OK\c\LContent-Type: text/html\r\L\r\L")
    client.safeSend(html & "\c\L")
    client.close()
  else:
    client.safeSend("Status: 405 Method Not Allowed\c\L\c\L")
    client.close()

proc cleanup(state: var TState) =
  echo("^C detected. Cleaning up...")
  for m in items(state.modules):
    # TODO: Send something to the modules to warn them?
    m.sock.close()
  
  state.sock.close()

when isMainModule:
  var configPath = ""
  if paramCount() > 0:
    configPath = paramStr(1)
    echo("Loading config ", configPath, "...")
  else:
    quit("Usage: ./website configPath")

  echo("Started website: built at ", CompileDate, " ", CompileTime)

  var state = website.open(configPath)
  #proc main() =
  var readSocks: seq[TSocket] = @[]
  while True:
    try:
      if state.scgi.next(200):
        handleRequest(state)
    except EScgi:
      echo("Got erroneous message from web server")
    
    readSocks = state.populateReadSocks()
    if select(readSocks, 10) != 0:
      if state.sock notin readSocks:
        # Connection from a module
        var (client, IPAddr) = state.sock.acceptAddr()
        if client == InvalidSocket: OSError()
        var clientS = @[client]
        # Wait 1.5 seconds for a greeting.
        if select(clientS, 1500) == 1:
          var line = ""
          assert client.recvLine(line)
          if state.parseGreeting(client, IPAddr, line):
            # Reply to the module
            client.send("{ \"reply\": \"OK\" }\c\L")
          else:
            client.send("{ \"reply\": \"FAIL\" }\c\L")
            echo("Rejected ", IPAddr)
            client.close()
      else:
        # Message from a module
        state.handleModuleMsg(readSocks)
    
    state.handlePings()
    
    state.database.keepAlive()
  
#  try:
#    main()
#  except EControlC:
#    cleanup(state)

