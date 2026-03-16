const c = @cImport({
    @cInclude("zpk3_imgui_bridge.h");
});

pub fn setup(dark_theme: bool) void {
    c.zpk3ImGuiSetup(dark_theme);
}

pub fn begin() void {
    c.zpk3ImGuiBegin();
}

pub fn end() void {
    c.zpk3ImGuiEnd();
}

pub fn shutdown() void {
    c.zpk3ImGuiShutdown();
}

pub fn wantCaptureMouse() bool {
    return c.zpk3ImGuiWantCaptureMouse();
}

pub fn wantCaptureKeyboard() bool {
    return c.zpk3ImGuiWantCaptureKeyboard();
}

pub fn setNextWindowSize(width: f32, height: f32) void {
    c.zpk3ImGuiSetNextWindowSize(width, height);
}

pub fn setNextWindowPos(x: f32, y: f32) void {
    c.zpk3ImGuiSetNextWindowPos(x, y);
}

pub fn beginWindow(title: [:0]const u8, open: ?*bool) bool {
    return c.zpk3ImGuiBeginWindow(title.ptr, if (open) |value| value else null);
}

pub fn endWindow() void {
    c.zpk3ImGuiEndWindow();
}

pub fn text(value: [:0]const u8) void {
    c.zpk3ImGuiText(value.ptr);
}

pub fn separator() void {
    c.zpk3ImGuiSeparator();
}

pub fn sameLine() void {
    c.zpk3ImGuiSameLine();
}

pub fn checkbox(label: [:0]const u8, value: *bool) bool {
    return c.zpk3ImGuiCheckbox(label.ptr, value);
}

pub fn button(label: [:0]const u8) bool {
    return c.zpk3ImGuiButton(label.ptr);
}

pub fn selectable(label: [:0]const u8, selected: bool) bool {
    return c.zpk3ImGuiSelectable(label.ptr, selected);
}

pub fn beginChild(id: [:0]const u8, width: f32, height: f32, border: bool) void {
    c.zpk3ImGuiBeginChild(id.ptr, width, height, border);
}

pub fn endChild() void {
    c.zpk3ImGuiEndChild();
}
