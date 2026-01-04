require "mkmf"

$CFLAGS << " -fobjc-arc"
$LDFLAGS << " -framework Cocoa -framework Metal -framework QuartzCore"

create_makefile("metaco/metaco")
