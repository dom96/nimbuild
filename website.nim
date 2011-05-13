## This is the SCGI Website and the hub.
import sockets, json, strutils, os, scgi, strtabs
import types, db

type
  TState = object
    sock: TSocket ## Hub server socket. All modules connect to this.
    modules: seq[TModule]
    scgi: TScgiState
    database: TDb
    platforms: seq[tuple[platform: string, status: TStatus]]

  TModule = object
    name: string
    sock: TSocket ## Client socket
    connected: bool
    platform: string


proc open(port: TPort = TPort(5123), scgiPort: TPort = TPort(5001), 
          databasePort = dbPort): TState =
  result.sock = socket()
  if result.sock == InvalidSocket: OSError()
  result.sock.bindAddr(TPort(5123))
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

proc parseGreeting(state: var TState, client: var TSocket, line: string) =
  # { "name": "modulename" }
  var json = parseJson(line)
  var module: TModule
  module.name = json["name"].str
  module.sock = client
  module.platform = json["platform"].str
  state.platforms.add((module.platform, initStatus()))
  echo(module.name, " connected.")
  state.modules.add(module)

proc `[]`*(ps: seq[tuple[platform: string, status: TStatus]],
           platform: string): TStatus =
  assert(ps.len > 0)
  for p, s in items(ps):
    if p == platform:
      return s
  raise newException(EInvalidValue, "Platform not in platforms")

proc `[]=`*(ps: var seq[tuple[platform: string, status: TStatus]],
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
  
  ps.add((platform, status))

proc setStatus(state: var TState, p: string, status: TStatusEnum,
               desc, hash: string) =
  var s = state.platforms[p]
  s.status = status
  s.desc = desc
  s.hash = hash
  state.platforms[p] = s

proc parseMessage(state: var TState, m: TModule, line: string) =
  var json = parseJson(line)
  # { "status": -1, desc: "...", platform: "...", hash: "123456" }
  if json.existsKey("status"):
    assert(json.existsKey("hash"))
    var hash = json["hash"].str
    
    case TStatusEnum(json["status"].num)
    of sBuildFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildFailure, json["desc"].str, hash)
      state.database.addCommit(hash, m.platform, bFail)
    of sBuildInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildInProgress, json["desc"].str, hash)
    of sBuildSuccess:
      state.setStatus(m.platform, sBuildSuccess, "", hash)
      state.database.addCommit(hash, m.platform, bSuccess)
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
      state.setStatus(m.platform, sTestSuccess, "", hash)
      state.database.updateProperty(hash, m.platform,
          "testResult", $int(tSuccess))
    of sUnknown:
      assert(false)
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
  
  # Remove disconnected modules
  var removed = 0
  for i in items(disconnect):
    state.modules.del(i-removed)
    inc(removed)

# SCGI
include "index.html"

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
    if state.scgi.next(200):
      handleRequest(state)
  
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
          client.send("{ \"status\": \"OK\" }\c\L")
      else:
        # Message from a module
        state.handleModuleMsg(readSocks)
    
    state.database.keepAlive()
        
