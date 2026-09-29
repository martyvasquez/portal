#!/bin/zsh
# Opens a Portal surface from the terminal: launcher | clipboard | new | settings | page:<general|quicklinks|snippets|openWith|clipboard|sync>
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"com.martyvasquez.portal.show\"), object: \"${1:-settings}\", userInfo: nil, deliverImmediately: true)"
