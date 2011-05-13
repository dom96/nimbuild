# This module is used by the website.
import redis, times
from sockets import TPort

type
  TDb* = object
    r: TRedis
    lastPing: float

  TBuildResult* = enum
    bFail, bSuccess

  TTestResult* = enum
    tFail, tSuccess

const
  listName = "commits"
  dbPort* = TPort(6379)
  failOnExisting = False

proc open*(host = "localhost", port = dbPort): TDb =
  result.r = redis.open(host, port)
  result.lastPing = epochTime()

proc customHSet(database: TDb, name, field, value: string) =
  if database.r.hSet(name, field, value).int == 0:
    if failOnExisting:
      assert(false)
    else:
      echo("[Warning:REDIS] ", field, " already exists in ", name)

proc addCommit*(database: TDb, commitHash, platform: string,
               built: TBuildResult, failReason: string = "") =
  var name = platform & ":" & commitHash
  if database.r.exists(name):
    if failOnExisting: quit("[FAIL] " & name & " already exists!", 1)
    else: echo("[Warning] " & name & " already exists!")
    
  discard database.r.lPush(listName, commitHash)
  
  database.customHSet(name, "buildResult", $int(built))
  if failReason != "":
    database.customHSet(name, "failReason", failReason)

proc updateProperty*(database: TDb, commitHash, platform, property,
                    value: string) =
  var name = platform & ":" & commitHash
  if database.r.hSet(name, property, value).int == 0:
    echo("[INFO:REDIS] 1 field updated in hash")
  else:
    echo("[INFO:REDIS] 1 new field added to hash")

proc keepAlive*(database: var TDb) =
  ## Keep the connection alive. Ping redis in this case. This functions does
  ## not guarantee that redis will be pinged.
  var t = epochTime()
  if t - database.lastPing >= 60.0:
    echo("PING -> redis")
    assert(TRedisStatus(database.r.ping()) == "PONG")
    database.lastPing = t
