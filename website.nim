## This is the SCGI Website and the hub.
import sockets, json, strutils, os, scgi, strtabs
import types, db

type
  HPlatformStatus = seq[tuple[platform: string, status: TStatus]]
  
  TState = object
    sock: TSocket ## Hub server socket. All modules connect to this.
    modules: seq[TModule]
    scgi: TScgiState
    database: TDb
    platforms: HPlatformStatus

  TModule = object
    name: string
    sock: TSocket ## Client socket
    connected: bool
    platform: string

proc open(port: TPort = TPort(5123), scgiPort: TPort = TPort(5001), 
          databasePort = dbPort): TState =
  result.sock = socket()
  if result.sock == InvalidSocket: OSError()
  result.sock.bindAddr(TPort(5123), "localhost")
  result.sock.listen()
  result.modules = @[]
  result.platforms = @[]

  # Open scgi instance
  result.scgi.open(scgiPort)
  
  # Connect to the database
  result.database = open("localhost", databasePort)

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

proc parseGreeting(state: var TState, client: var TSocket, line: string) =
  # { "name": "modulename" }
  var json = parseJson(line)
  var module: TModule
  module.name = json["name"].str
  module.sock = client
  module.platform = json["platform"].str
  echo(module.name, " connected.")
  state.modules.add(module)
  
  # Only add this module platform to platforms if it's a `builder`, and
  # if platform doesn't already exist.
  if module.name == "builder":
    if module.platform notin state.platforms:
      state.platforms.add((module.platform, initStatus()))

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

proc parseMessage(state: var TState, m: TModule, line: string) =
  var json = parseJson(line)
  if json.existsKey("status"):
    # { "status": -1, desc: "...", platform: "...", hash: "123456" }
    assert(json.existsKey("hash"))
    var hash = json["hash"].str

    case TStatusEnum(json["status"].num)
    of sBuildFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildFailure, json["desc"].str, hash)
      state.database.updateProperty(hash, m.platform, "buildResult", 
                                    $int(bFail))
      state.database.updateProperty(hash, m.platform, "failReason", 
                                    json["desc"].str)
    of sBuildInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildInProgress, json["desc"].str, hash)
    of sBuildSuccess:
      assert(json.existsKey("websiteURL"))
      state.setStatus(m.platform, sBuildSuccess, "", hash)
      state.database.updateProperty(hash, m.platform, "buildResult", 
                                    $int(bSuccess))
      state.database.updateProperty(hash, m.platform, "websiteURL", 
                                    json["websiteURL"].str)
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
    of sUnknown:
      assert(false)
  elif json.existsKey("payload"):
    # { "payload": { .. } }
    # Send this message to the "builder" modules
    if "builder" in state.modules:
      for module in items(state.modules):
        if module.name == "builder":
          # Add commit to database
          state.database.addCommit(json["payload"]["after"].str,
              module.platform, json["payload"]["commits"][0]["message"].str)
          
          module.sock.send($json & "\c\L")
  else:
    echo("[Fatal] Not implemented")
    assert(false)
      
proc handleModuleMsg(state: var TState, readSocks: seq[TSocket]) =
  var disconnect: seq[int] = @[] # Modules which disconnected
  for i in 0..state.modules.len()-1:
    var m = state.modules[i] 
    if m.sock notin readSocks:
      var line = ""
      if recvLine(m.sock, line):
        echo("Got line from $1: $2" % [m.name, line])
        state.parseMessage(m, line)
      else:
        # Assume the module disconnected
        echo(m.name, " disconnected.")
        disconnect.add(i)
        # Remove from platforms if this is a builder.
        if m.name == "builder":
          for i in 0..len(state.platforms):
            if state.platforms[i].platform == m.platform:
              state.platforms.delete(i)
              break
  
  # Remove disconnected modules
  var removed = 0
  for i in items(disconnect):
    state.modules.delete(i-removed)
    inc(removed)

# HTML Generation

proc joinUrl(u, u2: string): string =
  if u.endswith("/"):
    return u & u2
  else: return u & "/" & u2

proc genPlatformResult(p: TCommit, platforms: HPlatformStatus): string =
  result = ""
  var weburl = joinUrl(p.websiteUrl, "commits/$1/nimrod_$2/" % 
                                     [p.platform, p.hash[0..11]])
  var logurl = joinUrl(weburl, "log.txt")
  case p.buildResult
  of bUnknown:
    if p.platform in platforms:
      if platforms[p.platform].hash == p.hash:
        result.add("<img src=\"static/images/progress.gif\"/>")
  of bFail: 
    result.add("<a href=\"$1\" class=\"fail\">fail</a>" % [logurl])
  of bSuccess: result.add("ok")
  result.add(" ")
  case p.testResult
  of tUnknown:
    if p.platform in platforms:
      if platforms[p.platform].hash == p.hash:
        result.add("<img src=\"static/images/progress.gif\"/>")
  of tFail:
    result.add("<a href=\"$1\" class=\"fail\">fail</a>" % [logurl])
  of tSuccess:
    var testresultsURL = joinUrl(weburl, "testresults.html")
    var percentage = float(p.passed) / float(p.total - p.skipped) * 100.0
    result.add("<a href=\"$1\" class=\"success\">" % [testresultsURL] &
               formatFloat(percentage, precision=4) & "%</a>")

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

  if headers["REQUEST_METHOD"] == "GET":
    var hostname = gethostbyaddr(headers["REMOTE_ADDR"]).name
    echo("Got website request from ", hostname)
    var html = state.genHtml()
    client.safeSend("Status: 200 OK\c\LContent-Type: text/html\r\L\r\L")
    client.safeSend(html & "\c\L")
    client.close()
  else:
    client.safeSend("Status: 405 Method Not Allowed\c\L\c\L")
    client.close()

when isMainModule:
  var state = website.open()
  var readSocks: seq[TSocket] = @[]
  while True:
    try:
      if state.scgi.next(200):
        handleRequest(state)
    except EScgi:
      echo("Got erroneous message")
    
    readSocks = state.populateReadSocks()
    if select(readSocks, 10) != 0:
      if state.sock notin readSocks:
        # Connection from a module
        var client = state.sock.accept()
        if client == InvalidSocket: OSError()
        var clientS = @[client]
        # Wait 1.5 seconds for a greeting.
        if select(clientS, 1500) == 1:
          var line = ""
          assert client.recvLine(line)
          state.parseGreeting(client, line)
          # Reply to the module
          client.send("{ \"reply\": \"OK\" }\c\L")
      else:
        # Message from a module
        state.handleModuleMsg(readSocks)
    
    state.database.keepAlive()
        
