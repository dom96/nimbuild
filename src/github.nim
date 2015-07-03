import strtabs, sockets, scgi, strutils, os, json,
  osproc, streams, times, parseopt, parseutils

from cgi import URLDecode
from httpclient import get # httpclient.post conflicts with jester.post
from net import nil

import asyncio
import asyncdispatch except Port, newDispatcher

import jester
import types


type
  TSubnet = object
    cidr: range[8 .. 32]
    a, b, c, d: int

  PState = ref TState
  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket
    scgi: PAsyncScgiState
    platform: string

    hubPort: TPort
    scgiPort: net.Port

    timeReconnected: float

    subnets: seq[TSubnet] # TODO: Separate into a TGithubAPI object.
    apiETag: string
    lastAPIAccess: float

when not defined(ssl):
  {.error: "Need SSL support to get Github's IPs, compile with -d:ssl.".}

# Command line reading
proc getCommandArgs(state: PState) =
  for kind, key, value in getOpt():
    case kind
    of cmdArgument:
      quit("Syntax: ./github --hp:hubPort --sp:scgiPort")
    of cmdLongOption, cmdShortOption:
      if value == "":
        quit("Syntax: ./github --hp:hubPort --sp:scgiPort")
      case key
      of "hubPort", "hp":
        state.hubPort = TPort(parseInt(value))
      of "scgiPort", "sp":
        state.scgiPort = net.Port(parseInt(value))
      else: quit("Syntax: ./github -hp hubPort -sp scgiPort")
    of cmdEnd: assert false

# Github specific

# -- subnets

proc invalidSubnet(msg: string = "Invalid subnet") =
  raise newException(EInvalidValue, msg)

proc parseSubnet(subnet: string): TSubnet =
  var i = 0

  template parsePart(letter: expr, dot: bool) =
    var j = parseInt(subnet, letter, i)
    if j <= 0: invalidSubnet()
    inc(i, j)
    if dot:
      if subnet[i] == '.': inc(i)
      else: invalidSubnet("Invalid subnet, expected '.'.")

  parsePart(result.a, true)
  parsePart(result.b, true)
  parsePart(result.c, true)
  parsePart(result.d, false)
  # Parse CIDR
  if subnet[i] != '/': invalidSubnet("Invalid subnet, expected '/'.")
  inc(i)
  var cidr = 0
  let j = parseInt(subnet, cidr, i)
  if j <= 0: invalidSubnet("Invalid subnet, expected int after '/'.")
  inc(i, j)
  if subnet[i] != '\0': invalidSubnet("Invalid subnet, expected \0.")
  result.cidr = cidr

proc calcSubmask(cidr: range[8 .. 32]): int =
  for i in 0 .. int(cidr)-1:
    result = 1 shl (i+(32-cidr)) or result

proc contains(subnet: TSubnet, ip: string): bool =
  # http://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing#CIDR_blocks
  let submask = (not calcSubmask(subnet.cidr)) and 0xFFFFFFFF # Mask to 32bits
  let subnetIP = subnet.a shl 24 or subnet.b shl 16 or
                 subnet.c shl 8 or subnet.d
  let ipmask = parseIP4(ip)
  result = (subnetIP or submask) == (ipmask or submask)

proc getHookSubnets(state: PState, timeout = 3000) =
  ## Gets the allowed IP addresses using Github's API.
  except: echo("  [Warning] Getting hookSubnets failed: ", getCurrentExceptionMsg())

  if epochTime() - state.lastAPIAccess < 5.0:
    return

  var extraHeaders =
    if state.apiETag != "": "If-None-Match: \"" & state.apiETag & "\"\c\L"
    else: ""
  let resp = httpclient.get("https://api.github.com/meta", extraHeaders)
  state.lastAPIAccess = epochTime()
  if resp.status[0] in {'4', '5'}:
    echo("  [Warning] HookSubnets won't change. Status code was: ", resp.status)
    return
  elif resp.status[0 .. 2] == "304":
    # Nothing changed.
    return

  let j = parseJSON(resp.body)
  if j.existsKey("hooks"):
    for ip in j["hooks"]: state.subnets.add(parseSubnet(ip.str))

  state.apiETag = resp.headers["ETag"]

# Communication

proc parseReply(line: string, expect: string): bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc hubConnect(state: PState)
proc handleConnect(s: PAsyncSocket, state: PState) =
  try:
    # Send greeting
    var obj = newJObject()
    obj["name"] = newJString("github")
    obj["platform"] = newJString(state.platform)
    obj["version"] = %"1"
    state.sock.send($obj & "\c\L")
    # Wait for reply.
    var line = ""
    sleep(1500)
    if state.sock.readLine(line):
      assert(line != "")
      doAssert parseReply(line, "OK")
      echo("The hub accepted me!")
    else:
      raise newException(EInvalidValue,
                         "Hub didn't accept me. Waited 1.5 seconds.")
  except EOS:
    echo(getCurrentExceptionMsg())
    s.close()
    echo("Waiting 5 seconds.")
    sleep(5000)
    state.hubConnect()

proc handleMessage(state: PState, line: string) =
  echo("Got message from hub: ", line)

proc handleModuleMessage(s: PAsyncSocket, state: PState) =
  var line = ""
  if not state.sock.readLine(line): return # Didn't receive a full line.
  if line != "":
    state.handleMessage(line)
  else:
    state.sock.close()
    echo("Disconnected from hub: ", osErrorMsg())
    echo("Reconnecting...")
    state.hubConnect()

proc hubConnect(state: PState) =
  state.sock = asyncSocket()
  state.sock.connect("127.0.0.1", state.hubPort)
  state.sock.handleConnect =
    proc (s: PAsyncSocket) {.gcsafe.} = handleConnect(s, state)
  state.sock.handleRead =
    proc (s: PAsyncSocket) {.gcsafe.} = handleModuleMessage(s, state)
  state.dispatcher.register(state.sock)

  state.platform = "linux-x86"
  state.timeReconnected = -1.0

proc open(port: TPort = TPort(9321),
          scgiPort: net.Port = net.Port(9323)): PState =
  new(result)

  result.dispatcher = newDispatcher()

  result.hubPort = port
  result.scgiPort = scgiPort
  result.subnets = @[]

  result.getCommandArgs()

  result.hubConnect()

  result.apiETag = ""
  getHookSubnets(result, timeout = -1) # Get initial set of subnets


proc sendBuild(sock: PAsyncSocket, payload: PJsonNode) =
  var obj = newJObject()
  obj["payload"] = payload
  sock.send($obj & "\c\L")

proc contains(subnets: seq[TSubnet], ip: string): bool =
  for subnet in subnets:
    if ip in subnet:
      return true

proc isAuthorized(state: PState, ip: string): bool =
  result = ip in state.subnets
  if result == false:
    # Update subnet list
    getHookSubnets(state)
    result = ip in state.subnets

when isMainModule:
  var state = open()

  settings:
    port = state.scgiPort

  routes:
    post "/":
      let realIP =
        if request.ip == "127.0.0.1":
          request.headers["X-Real-IP"]
        else:
          request.ip
      echo("[POST] ", realIP)
      var hostname = ""
      try:
        hostname = getHostByAddr(realIP).name
      except:
        hostname = getCurrentExceptionMsg()
      echo("       ", hostname)
      let authorized = state.isAuthorized(realIP)
      echo("       ", if authorized: "Authorized." else: "Denied.")
      cond authorized
      let payload = @"payload"

      echo("       Payload:")
      for line in splitLines(payload):
        echo("       ", line)

      var json = parseJSON(payload)
      if json.hasKey("after"):
        sendBuild(state.sock, json)
        echo("       ", json["after"].str)
      resp "Cheers, Github."

  while true:
    asyncdispatch.poll()
    discard state.dispatcher.poll()

