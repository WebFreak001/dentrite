/// Chapter 6: commands with shortcuts, menus, a context menu, a dialog and tooltips.
module guide.commands;

import dentrite.command;
import dentrite.containers;
import dentrite.host : Host;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.dialog;
import dentrite.widgets.icons;
import dentrite.widgets.label;
import dentrite.widgets.menu;
import dentrite.widgets.textarea;
import dentrite.widgets.tooltip : commandTip;
import std.uni : toUpper;

/// Note editor: the text, the text as last saved, and whether saving follows every change.
final class Notes
{
    Signal!string text;     /// content
    Signal!string saved;    /// content at the last save
    Computed!bool dirty;    /// changed since saved
    Signal!bool autosave;   /// save on every change
    int saves;              /// saves so far

    /// Empty, saved notes.
    this()
    {
        text = signal("");
        saved = signal("");
        dirty = computed(() => text.get != saved.get);
        autosave = signal(false);
    }

    /// Marks the text saved.
    void save()
    {
        saved.set(text.peek);
        ++saves;
    }
}

/// Commands of the editor. Menus, tool bar buttons and shortcuts all run these.
struct NoteCommands
{
    Command save;     /// Ctrl+S, while dirty
    Command clear;    /// asks first
    Command autosave; /// checked while saving on every change
    Command quit;     /// Ctrl+Q
    Command upper;    /// Ctrl+U, while the text has focus
}

/// Editor window contents in `h`: a menu bar, a tool bar, the text with a context menu and a shortcut of its own,
/// and a confirmation.
Node editor(Host h, Notes n)
{
    Dialog confirm = dialog("Clear the notes?", buttons: ["Cancel", "Clear"], primary: 1, primaryVariant: "danger",
        onClose: (int b) {
            if (b == 1)
            {
                n.text.set("");
            }
        })(label("The text goes away for good.", wrap: true));
    NoteCommands c;
    c.save = command("&Save", &n.save, keys: "Ctrl+S", enabled: &n.dirty.get);
    c.clear = command("C&lear", () { confirm.open(h); }, icon: Icon.stop, enabled: () => n.text.get.length > 0);
    c.autosave = command("&Autosave", () { n.autosave.set(n.autosave.peek == false); }, checked: &n.autosave.get);
    c.quit = command("&Quit", () { h.running = false; }, keys: "Ctrl+Q");
    c.upper = command("&Upper case", () { n.text.set(n.text.peek.toUpper); }, keys: "Ctrl+U");
    effect(() {
        if (n.autosave.get && n.dirty.get)
        {
            n.save();
        }
    });

    return column()(
        menuBar(
            menu("&File")(menuItem(c.save), menuItem(c.autosave), menuSeparator(), menuItem(c.quit)),
            menu("&Edit")(menuItem(c.clear)),
        ),
        panel(variant: "toolbar")(row(gap: 4)(
            button("Save", onClick: () { c.save.run(); }, variant: "toolbar", enabled: &c.save.isEnabled,
                tooltip: commandTip(c.save)),
            button("Clear", onClick: () { c.clear.run(); }, icon: Icon.stop, variant: "toolbar",
                enabled: &c.clear.isEnabled, tooltip: "Clears the notes, after asking"),
            spacer(),
            label(() => n.dirty.get ? "Changed" : "Saved", "muted"),
        )),
        expanded(shortcuts([c.upper])(contextMenu(menuItem(c.upper), menuItem(c.clear))(
            textArea(n.text, placeholder: "Notes", wrap: true, accessName: "Notes")))),
    );
}

/// The menu bar fires its items' shortcuts, Ctrl+U works only in the text, and the dialog asks before clearing.
unittest
{
    import guide.harness;

    Host h = testHost(500, 400);
    scope (exit)
    {
        h.close();
    }
    Notes n = new Notes;
    scope Scope root = effectScope(() { h.setRoot(editor(h, n)); });
    h.frame();
    assert(shows(h, Role.label, "Saved"));
    h.injectKey('s', Mod.ctrl);
    assert(n.saves == 0, "nothing to save");

    h.click(Role.multilineTextInput, "Notes");
    h.injectText("Buy milk");
    h.frame();
    assert(n.dirty.get && shows(h, Role.label, "Changed"));
    h.injectKey('s', Mod.ctrl);
    h.frame();
    assert(n.saves == 1 && shows(h, Role.label, "Saved"));

    h.click(Role.menuItem, "File");
    h.click(Role.menuItemCheckBox, "Autosave");
    assert(n.autosave.peek);
    h.click(Role.multilineTextInput, "Notes");
    h.injectText(" and eggs");
    h.frame();
    assert(n.saves == 2 && n.saved.peek == "Buy milk and eggs");
    h.injectKey('u', Mod.ctrl);
    assert(n.text.peek == "BUY MILK AND EGGS", "focus is in the text");
    n.text.set("Buy milk and eggs");
    h.setFocus(null);
    h.injectKey('u', Mod.ctrl);
    assert(n.text.peek == "Buy milk and eggs", "focus left the text");

    h.click(Role.button, "Clear");
    assert(shows(h, Role.dialog, "Clear the notes?"));
    h.injectKey(Key.escape);
    h.frame();
    assert(n.text.peek.length > 0, "Escape cancels");
    h.click(Role.button, "Clear");
    h.injectKey(Key.enter);
    h.frame();
    assert(n.text.peek == "", "Enter presses the main button");
}
