#!/bin/zsh
# Makes what Shell's screenshots (.dev/screenshots.json) run in, so the pictures never show anyone's real work: a zsh
# setup with a plain prompt (ZDOTDIR) and a small git project for the terminal to show. The folder's path shows in
# the window's title, hence a short one outside the repo.
# Usage: Tools/screenshots/make-demo.sh [folder]   (default /tmp/ShellDemo, as .dev/screenshots.json expects)
set -euo pipefail
demo=${1:-/tmp/ShellDemo}
rm -rf "$demo"
mkdir -p "$demo/zsh" "$demo/atlas"

cat > "$demo/zsh/.zshrc" <<ZSHRC
# The demo's shell: none of the user's setup, a short prompt, no history file.
unsetopt HIST_SAVE_NO_DUPS 2>/dev/null
HISTFILE=/dev/null
export PS1='%F{green}maya@atlas%f %F{cyan}%1~%f %# '
export CLICOLOR=1
cd "$demo/atlas"
ZSHRC

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Maya Okafor" GIT_AUTHOR_EMAIL=maya@example.com
export GIT_COMMITTER_NAME="Maya Okafor" GIT_COMMITTER_EMAIL=maya@example.com
cd "$demo/atlas"
git init -q -b main
mkdir -p Sources/Atlas Tests/AtlasTests
step=0
commit() {
  step=$((step + 1))
  export GIT_AUTHOR_DATE=$(date -u -j -v-9d -v+$((step * 19))H +%Y-%m-%dT%H:%M:%SZ)
  export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE
  git add -A && git commit -q -m "$1"
}
print '// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: "Atlas")' > Package.swift
print '# Atlas\n\nPlans trips: stops, bookings and the days between them.' > README.md
commit "Started the Atlas package"
print 'struct Trip {\n  var name: String\n  var days: Int\n}' > Sources/Atlas/Trip.swift
commit "Added trips"
print 'struct Stop {\n  var name: String\n  var day: Int\n}' > Sources/Atlas/Stop.swift
commit "Added stops to a day"
print 'final class TripStore {\n  private(set) var trips: [Trip] = []\n}' > Sources/Atlas/TripStore.swift
commit "Kept trips in a store"
print 'import Testing\n@testable import Atlas\n\n@Test func emptyStore() { #expect(TripStore().trips.isEmpty) }' > Tests/AtlasTests/TripStoreTests.swift
commit "Tested the empty store"
git tag v1.0
print 'Bookings show their confirmation number.' >> README.md
commit "Documented bookings"
print '\n// Offline maps arrive in 2.1.' >> Sources/Atlas/Trip.swift
echo "$demo"
