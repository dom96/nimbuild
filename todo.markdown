* <del>Save the website URL of each builder to the database, then provide URLs on the website.</del>
* <del>Save more information to the database, e.g. commit message, number of tests passed and failed.</del>
* <del>Design the website.</del>
* Keep only the latest version of Nimrod for download.
* <del>Doc generation!</del>
* grep "TODO"
* <del>Generate C Sources for every platform.</del>
* <del>Include GPL license in with the distribution. Also readme file which mentions that this is a minimal distribution.</del>
* Redesign
* Fix nimbot
* Integration with Github status API
  * When a pull request is made nimbuild should be intelligent on what it compiles
    I.e. If the file edited is in the compiler/ directory then nimrod should be bootstrapped
    if the file edited is a test, the test should be ran
    if the file edited is a module in the stdlib it should just be compiled
    * This should then be reported to github...

* Nimbuild should be smart, as described above, this should be replicated to
  all pushes. Single file change: build only that file, compiler changes do whole bootstrap + test suite.
  etc.
  * If the newest build only built one file, the website should show the last known test results (perhaps with a warning).
    * DB needs to know about this.