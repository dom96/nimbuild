import asyncdispatch, asyncnet, logging, json, uri, strutils, future

import common/client, common/state, common/messages, asyncproc

# Build specs
import common, buildSpecs/nim

type
  Builder = ref object
    client: Client
    build: Build

proc start(build: Build, repo, hash: string) {.async.} =
  let path = repo.parseUri().path.toLower()
  case path
  of "/araq/nim":
    await nim.spec(build, repo, hash)
  else:
    warn("Cannot build '" & path & "'.")

proc onProgress(builder: Builder, message: ProcessEvent) {.async.} =
  debug($message.kind)
  case message.kind
  of ProcessStdout:
    info(message.data)
  else: discard

proc onMessage(builder: Builder, message: JsonNode) {.async.} =
  debug("onMessage")
  case message["event"].getStr
  of "accepted":
    # TODO: just for testing.
    asyncCheck start(builder.build, "https://github.com/Araq/Nim", "devel")
  else: discard

proc newBuilder(): Builder =
  var cres: Builder
  new cres

  cres.client = newClient("builder")

  cres.build = newBuild(
      ((msg: ProcessEvent) -> Future[void]) => (onProgress(cres, msg)))
  return cres

proc main() {.async.} =
  # Set up logging.
  var console = newConsoleLogger(fmtStr = verboseFmtStr)
  addHandler(console)

  var builder = newBuilder()

  await builder.client.start("localhost", Port(5123))

  while true:
    let msg = await builder.client.next()
    await onMessage(builder, msg)

waitFor main()
