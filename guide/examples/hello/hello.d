/// The smallest dentrite program: a window with a counter. `dub run -c hello` from `guide/examples/`.
module hello;

import dentrite.containers;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.label;
import dentrite.window;
import std.format : format;

/// Opens the window and runs until it closes.
void main()
{
    WindowOptions o;
    o.title = "Hello";
    o.width = 320;
    o.height = 200;
    o.fonts = ["../../fonts/Inter-Regular.otf", "../../fonts/Inter-SemiBold.otf",
        "../../fonts/JetBrainsMono-Regular.ttf"];
    scope Window w = new Window(o);

    Signal!int count = signal(0);
    scope Scope root = effectScope(() {
        w.setRoot(pad(all: 16)(column(gap: 8, cross: CrossAlign.start)(
            label(() => format("Count: %d", count.get)),
            button("Add one", onClick: () { count.set(count.peek + 1); }),
        )));
    });
    w.run();
}
