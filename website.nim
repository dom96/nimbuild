## This is the SCGI Website and the hub.
import 
  sockets, asyncio, json, strutils, os, scgi, strtabs, times, streams, parsecfg
import types, db

const
  websiteURL = "http://dom96.co.cc/nimbuild/"

type
  HPlatformStatus = seq[tuple[platform: string, status: TStatus]]
  
  PState = ref TState
  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket ## Hub server socket. All modules connect to this.
    modules: seq[TModule]
    scgi: PAsyncScgiState
    database: TDb
    platforms: HPlatformStatus
    password: string ## The password that foreign modules need to be accepted.
    bindAddr: string
    bindPort: int
    scgiPort: int
    redisPort: int

  TModuleStatus = enum
    MSConnecting, ## Module connected, but has not sent the greeting.
    MSConnected ## Module is ready to do work.

  TModule = object
    name: string
    sock: PAsyncSocket ## Client socket
    status: TModuleStatus
    platform: string
    lastPong: float
    pinged: bool # whether we are waiting for a pong from the module.
    ping: float # in seconds
    ip: string # IP address this module is connecting from
    delegID: PDelegate

proc parseConfig(state: PState, path: string) =
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

proc handleAccept(s: PAsyncSocket, arg: PObject)
proc handleRequest(server: var TAsyncScgiState, client: TSocket, 
                   input: string, headers: PStringTable, userArg: PObject)
proc open(configPath: string): PState =
  new(result)
  parseConfig(result, configPath)
  result.dispatcher = newDispatcher()

  result.sock = AsyncSocket(userArg = result)
  result.sock.bindAddr(TPort(result.bindPort), result.bindAddr)
  result.sock.listen()
  result.sock.handleAccept = handleAccept
  result.modules = @[]
  result.platforms = @[]
  
  result.dispatcher.register(result.sock)
  
  # Open scgi instance
  result.scgi = open(handleRequest, TPort(result.scgiPort), userArg = result)
  result.dispatcher.register(result.scgi)
  
  # Connect to the database
  try:
    result.database = db.open("localhost", TPort(result.redisPort))
  except EOS:
    quit("Couldn't connect to redis: " & OSErrorMsg())

# Modules

proc contains(modules: seq[TModule], name: string): bool =
  for i in items(modules):
    if i.name == name: return true
  
  return false

proc contains(platforms: HPlatformStatus,
              p: string): bool =
  for platform, s in items(platforms):
    if platform == p:
      return True

proc handleModuleMsg(s: PAsyncSocket, arg: PObject)
proc addModule(state: PState, client: PAsyncSocket, IPAddr: string) =
  var module: TModule
  module.sock = client
  module.ip = IPAddr
  module.lastPong = epochTime()
  module.pinged = false
  module.status = MSConnecting
  echo(IPAddr, " connected.")

  # Add this module to the dispatcher.
  client.handleRead = handleModuleMsg
  client.userArg = state
  module.delegID = state.dispatcher.register(client)

  state.modules.add(module)

proc parseGreeting(state: PState, m: var TModule, line: string): bool =
  # { "name": "modulename" }
  var json: PJsonNode
  try:
    json = parseJson(line)
  except EJsonParsingError:
    return False

  if m.ip != "127.0.0.1":
    # Check for password
    var fail = true
    if json.existsKey("pass"):
      if json["pass"].str == state.password:
        fail = false
      else:
        echo("Got incorrect password: ", json["pass"].str)

    if fail: return false
  
  if not (json.existsKey("name") and json.existsKey("platform")): return false
  
  m.name = json["name"].str
  m.platform = json["platform"].str
  
  # Only add this module platform to platforms if it's a `builder`, and
  # if platform doesn't already exist.
  if m.name == "builder":
    if m.platform notin state.platforms:
      state.platforms.add((m.platform, initStatus()))
    else:
      echo("Platform(", m.platform, ") already exists.")
      return False
  
  m.status = MSConnected
  
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
  case module.status
  of MSConnected:
    result.add module.name
    result.add "-"
    result.add module.platform
    result.add "(" & module.ip & ")"
  of MSConnecting:
    result.add "Unknown (" & module.ip & ")"

proc remove(state: PState, module: TModule) =
  for i in 0..len(state.modules)-1:
    var m = state.modules[i]
    if m.name == module.name and
       m.platform == module.platform and 
       m.ip == module.ip:
      state.dispatcher.unregister(state.modules[i].delegID)
      state.modules[i].sock.close()
      echo(uniqueMName(state.modules[i]), " disconnected.")

      # if module is a builder remove it from platforms.
      if m.name == "builder":
        for p in 0..len(state.platforms)-1:
          if state.platforms[p].platform == m.platform:
            state.platforms.delete(p)
            break

      state.modules.delete(i)
      return

proc setStatus(state: PState, p: string, status: TStatusEnum,
               desc, hash: string) =
  var s = state.platforms[p]
  s.status = status
  s.desc = desc
  s.hash = hash
  echo("setStatus -- ", TStatusEnum(status), " -- ", p)
  state.platforms[p] = s

# TODO: Instead of using assertions provide a function which checks whether the
# key exists and throw an exception if it doesn't.

proc parseMessage(state: PState, mIndex: int, line: string) =
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

  elif json.existsKey("ping"):
    # Module thinks it's disconnected! Reply quickly!
    json["pong"] = json["ping"]
    json.delete("ping")
    m.sock.send($json & "\c\L")

  else:
    echo("[Fatal] Can't understand message from " & m.name & ": ",
         line)
    assert(false)

proc handleModuleMsg(s: PAsyncSocket, arg: PObject) =
  var state = PState(arg)
  # Module sent a message to us
  var disconnect: seq[TModule] = @[] # Modules which disconnected
  for i in 0..state.modules.len()-1:
    template m: expr = state.modules[i]
    if m.sock == s:
      var line = ""
      if recvLine(m.sock.getSocket, line):
        if line == "": 
          disconnect.add(m)
          continue
        case m.status
        of MSConnecting:
          if state.parseGreeting(m, line):
            m.sock.send("{ \"reply\": \"OK\" }\c\L")
            echo(uniqueMName(m), " accepted.")
          else:
            m.sock.send("{ \"reply\": \"FAIL\" }\c\L")
            echo("Rejected ", uniqueMName(m))
            disconnect.add(m)
        of MSConnected: 
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

proc handlePings(state: PState) =
  var remove: seq[TModule] = @[] # Modules that have timed out.
  for i in 0..state.modules.len-1:
    template module: expr = state.modules[i]
    var pingEvery = 100.0
    case module.status
    of MSConnected:
      if module.name == "builder":
        if module.platform.startsWith("windows"): pingEvery = 15000.0
      
        if module.pinged and (epochTime() - module.lastPong) >= 25.0:
          echo(uniqueMName(module),
               " has not replied to PING. Assuming timeout!!!")
          remove.add(module)
          continue

        if (epochTime() - module.lastPong) >= pingEvery:
          var obj = newJObject()
          obj["ping"] = newJString(formatFloat(epochTime()))
          module.sock.send($obj & "\c\L")
          module.lastPong = epochTime() # This is a bit misleading, but I don't
                                        # want to add lastPing
          module.pinged = true
          echo("Pinging ", uniqueMName(module))
    
    of MSConnecting:
      if (epochTime() - module.lastPong) >= 2.0:
        echo(uniqueMName(module), " did not send a greeting.")
        module.sock.send("{ \"reply\": \"FAIL\", \"desc\": \"Took too long\" }\c\L")
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

proc genCssPath(state: PState): string =
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
          var url = joinUrl(websiteUrl, "commits/$2/nimrod_$1.zip" %
                            [c.hash[0..11], platform.platform])
          var class = ""
          if i == 0: class = "left button"
          else: class = "middle button"
          
          result.add("<a href=\"$1\" class=\"$2\">$3$4</a>" %
                     [url, class, downloadSpan,
                      platform.platform & "-" & c.hash[0..11]])
                      
          if platform.csources and not cSrcs:
            var cSrcUrl = joinUrl(websiteUrl,
                                  "commits/$2/nimrod_$1_csources.zip" %
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

proc handleRequest(server: var TAsyncScgiState, client: TSocket, 
                   input: string, headers: PStringTable, userArg: PObject) =
  var state = PState(userArg)
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

proc cleanup(state: PState) =
  echo("^C detected. Cleaning up...")
  for m in items(state.modules):
    # TODO: Send something to the modules to warn them?
    m.sock.close()
  
  state.sock.close()

proc handleAccept(s: PAsyncSocket, arg: PObject) =
  var state = PState(arg)
  # Connection from a module
  var (client, IPAddr) = s.acceptAddr()
  var clientS = @[client.getSocket]
  state.addModule(client, IPAddr)

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
  while True:
    try:
      doAssert state.dispatcher.poll()
    except EScgi:
      echo("[Scgi] Got erronous message from http server.")
    
    state.handlePings()
    
    state.database.keepAlive()
  
#  try:
#    main()
#  except EControlC:
#    cleanup(state)

