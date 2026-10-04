#!/bin/zsh
# Opens a Portal surface from the terminal: launcher | clipboard | new | transform:<name>[:copy] (previews or copies it on the clipboard) | settings | page:<general|quicklinks|snippets|transformers|openWith|clipboard|chatgpt|sync>
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"com.martyvasquez.portal.show\"), object: \"${1:-settings}\", userInfo: nil, deliverImmediately: true)"
