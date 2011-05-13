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
Each field of that hash will provide information such as whether the build failed/succeeded etc.
Each field of this hash will also start with the platform name, for example ``linux-x86``. The platform and hash will be separated by a ``:``.
For example:

  linux-x86:12345678




