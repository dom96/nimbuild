# Structure
                    
         Github
             \
              \
           SCGI Website.
                  \
                   \
                   IRC?

## SCGI Website, a.k.a The Hub.

This serves the nimrod/build website, it also acts as a hub, all the "modules" connect to it. For now only Github and IRC.

## Github

This module waits for a request from Github which notifies it that there is a new commit in Nimrod's repo. Once a new commit is made it does ``git pull`` the local
version of the nimrod repo. After that it bootstraps Nimrod and runs the test suite. Reporting the progress to the SCGI Website along the way. (and maybe IRC too?)

## Communication

Lets say ``Github`` wants to send a message to the ``SCGI website`` that Nimrod is being currently built. A JSON encoded message will be sent, like this:

  { "buildStatus": 0 }

Another example is communication from Github to IRC.

  { "to": "IRC", "payload": { ... } }

This will simply be relayed to ``IRC`` by the ``SCGI Website``.

# Database

The current database that is being used is redis.

## Structure

### A list

This will be called ``commits``. Each commit hash will be LPUSH-ed onto this list for easy iteration from the latest to the oldest commits with LRANGE.

### Keys

Information about each commit will be saved in a hash by the name of ``commit_hash``.
The fields will be:
  * commitMsg
  * date
  * username
  * branch

Specific information about a build can be retrieved by accessing ``platform:commit_hash``, where ``platform`` can be for example "linux-x86".
The fields that these will contain will be:
  * buildResult -> db.TBuildResult ( bUnknown, bFail, bSuccess )
  * testResult  -> db.TTestResult  ( tUnknown, tFail, tSuccess )
  * total       -> total tests
  * passed      -> passed tests
  * skipped     -> skipped tests
  * failed      -> failed tests
  * csources    -> whether the csources have been built for this platform/commit combination ("t" or "f" (?))
  * timeBuild   -> Time taken to build TODO
  * timeTest    -> Time taken to test

