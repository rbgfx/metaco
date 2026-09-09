# frozen_string_literal: true

require "mkmf"

$CFLAGS << " -fobjc-arc"
$LDFLAGS << " -framework Cocoa -framework Metal -framework QuartzCore"
create_makefile("metaco_test")
