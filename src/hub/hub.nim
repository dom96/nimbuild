import asyncdispatch, asyncnet, times, logging, sets, json, os

import common/cfg, common/messages

type
  Client = ref object
    socket: AsyncSocket
    wantsEvents: HashSet[string] ## Events this client wants to receive.
    ping: float ## This client's lag.
    lastPing: float ## Last time this client was pinged.
    lastPong: float ## Last time a pong was received.
    address: string
    name: string

  Hub = ref object
    socket: AsyncSocket
    clients: seq[Client]
    config: Config

# Client functions.
proc newClient(socket: AsyncSocket, address, name: string): Client =
  Client(
    socket: socket,
    wantsEvents: initSet[string](),
    ping: -1,
    lastPing: 0,
    lastPong: 0,
    address: address,
    name: name
  )

proc timedOut(client: Client): bool =
  client.lastPing > client.lastPong and
    (epochTime() - client.lastPong) > 20

proc lastPinged(client: Client): float =
  epochTime() - client.lastPing 

proc waitingForPong(client: Client): bool =
  client.lastPing > client.lastPong

proc `$`(client: Client): string =
  client.name & " (" & client.address & ")"

proc sendError(client: Client, msg: string): Future[void] =
  client.socket.send(genMessage("error", %{"msg": %msg}))

# Hub functions.
proc pingClients(self: Hub) {.async.} =
  var newClients: seq[Client] = @[]
  for client in self.clients:
    if not client.timedOut:
      newClients.add client
    else:
      await client.sendError("Timed out.")
      info($client & " timed out.")
      client.socket.close()

    if client.lastPinged() > 60 and not client.waitingForPong():
      await client.socket.send(genMessage("ping", %{"time": %epochTime()}))
      client.lastPing = epochTime()
  self.clients = newClients

proc processClient(self: Hub, client: Client): Future[bool] {.async.} =
  let line = await client.socket.recvLine()
  if line == "": return false

  # Process the received message
  var propagate = true
  let message = parseMessage(line)
  if message.kind == JNull:
    await client.sendError("Invalid message.")
    info("Received incorrect message from " & $client)
    return false

  case message{"event"}.getStr()
  of "pong":
    client.lastPong = epochTime()
    client.ping = message{"args"}{"time"}.getFloat()
    propagate = false
  of "":
    await client.sendError("Invalid event.")
    info("Received incorrect event from " & $client)
    return false
  else: discard

  # Propagate the event to all clients.
  for client in self.clients:
    # TODO: Check wantEvents.
    await client.socket.send(line & "\c\l")

proc processClients(self: Hub) {.async.} =
  while true:
    var newClients: seq[Client] = @[]
    for client in self.clients:
      let keepClient = await processClient(self, client)
      if keepClient:
        newClients.add client
      else:
        client.socket.close()
    self.clients = newClients

proc loop(self: Hub) {.async.} =
  while true:
    await sleepAsync(5000)

    await pingClients(self)

proc checkWelcome(self: Hub, socket: AsyncSocket, address: string) {.async.} =
  info(address & " connected.")
  let welcomeMsg = parseMessage(await socket.recvLine())

  var verified = false
  if welcomeMsg.kind == JObject and welcomeMsg{"event"}.getStr() == "connected":
    let name = welcomeMsg{"args"}{"name"}.getStr()
    if name != "":
      verified = true
      # TODO: Want events.
      let c = newClient(socket, address, name)
      self.clients.add(c)
      info($c & " accepted.")

  if not verified:
    warn(address & " rejected.")
    socket.close()

proc serve(self: Hub) {.async.} =
  self.socket = newAsyncSocket()
  self.socket.bindAddr(self.config.getInt("hub.port", 5123).Port)
  self.socket.listen()

  asyncCheck loop(self)

  while true:
    let (address, socket) = await self.socket.acceptAddr()
    asyncCheck checkWelcome(self, socket, address)

proc newHub(): Hub =
  new result
  result.clients = @[]
  # Config
  let confPath = getCurrentDir() / "hub.ini"
  if existsFile(confPath):
    result.config = parse(confPath)
  else:
    result.config = newConfig()

when isMainModule:
  # Set up logging.
  var console = newConsoleLogger(fmtStr = verboseFmtStr)
  handlers.add(console)

  var h = newHub()
  waitFor serve(h)
