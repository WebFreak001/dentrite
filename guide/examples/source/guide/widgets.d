/// Chapter 4: the common widgets bound to signals, and setters driven by effects.
module guide.widgets;

import dentrite.containers;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.checkbox;
import dentrite.widgets.combobox;
import dentrite.widgets.icons;
import dentrite.widgets.label;
import dentrite.widgets.progress;
import dentrite.widgets.radio;
import dentrite.widgets.slider;
import dentrite.widgets.spinbox;
import dentrite.widgets.textbox;
import std.conv : to;
import std.format : format;
import std.string : capitalize;

/// Export quality.
enum Quality
{
    draft,  /// fast
    normal, /// default
    best,   /// slow
}

/// Export settings: what the export dialog of an app would read.
final class ExportSettings
{
    Signal!string name;       /// output file
    Signal!Quality quality;   /// how hard to try
    Signal!int width;         /// pixels
    Signal!bool keepAspect;   /// height follows the width
    Signal!string format;     /// file type
    Signal!double done;       /// progress of the running export, NaN while starting

    /// Defaults.
    this()
    {
        name = signal("render");
        quality = signal(Quality.normal);
        width = signal(1920);
        keepAspect = signal(true);
        format = signal("PNG");
        done = signal(0.0);
    }
}

/// Form over `s`: each widget takes the signal it edits.
Node exportForm(ExportSettings s)
{
    return column(gap: 10, cross: CrossAlign.start)(
        row(gap: 8)(label("Name"), sized(w: 200)(textBox(s.name, placeholder: "File name", accessName: "File name")),
            comboBox(["PNG", "JPEG", "WebP"], s.format, tooltip: "File type")),
        radioGroup(s.quality, label: (Quality q) => capitalize(q.to!string), horizontal: true),
        row(gap: 8)(label("Width"), sized(w: 200)(slider(s.width, 16, 4096, 16)), spinBox(s.width, 16, 4096, 16)),
        checkbox(s.keepAspect, "Keep the aspect ratio"),
        row(gap: 8)(
            button("Export", onClick: () { s.done.set(double.nan); }, icon: Icon.play, variant: "primary",
                enabled: () => s.name.get.length > 0, tooltip: "Writes the file"),
            sized(w: 160)(progressBar(() => s.done.get)),
        ),
        label(() => format("%s.%s at %d px, %s", s.name.get, s.format.get, s.width.get, s.quality.get), "muted"),
    );
}

/// Tool bar button whose caption, icon and tooltip follow `running`.
Node runButton(Signal!bool running)
{
    Button b = button("Run", onClick: () { running.set(running.peek == false); }, variant: "toolbar");
    effect(() {
        bool on = running.get;
        b.setCaption(on ? "Pause" : "Run");
        b.setIcon(on ? Icon.pause : Icon.play);
        b.setTooltip(on ? "Pause the target" : "Run the target");
    });
    return b;
}

/// Widgets write their signals, and bindings read them.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(700, 300);
    scope (exit)
    {
        h.close();
    }
    ExportSettings s = new ExportSettings;
    Signal!bool running = signal(false);
    scope Scope root = effectScope(() { h.setRoot(column()(exportForm(s), runButton(running))); });
    h.frame();
    h.click(Role.radioButton, "Best");
    assert(s.quality.peek == Quality.best);
    h.click(Role.checkBox, "Keep the aspect ratio");
    assert(s.keepAspect.peek == false);
    s.width.set(640);
    h.frame();
    assert(shows(h, Role.label, "render.PNG at 640 px, best"));
    s.name.set("");
    h.frame();
    h.click(Role.button, "Export");
    assert(s.done.peek == 0, "disabled while the name is empty");
    h.click(Role.button, "Run");
    assert(running.peek && shows(h, Role.button, "Pause"));
}
