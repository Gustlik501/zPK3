#include "zpk3_imgui_bridge.h"

#include "imgui.h"
#include "rlImGui.h"

extern "C" {

void zpk3ImGuiSetup(bool dark_theme) {
    rlImGuiSetup(dark_theme);
}

void zpk3ImGuiBegin(void) {
    rlImGuiBegin();
}

void zpk3ImGuiEnd(void) {
    rlImGuiEnd();
}

void zpk3ImGuiShutdown(void) {
    rlImGuiShutdown();
}

bool zpk3ImGuiWantCaptureMouse(void) {
    return ImGui::GetIO().WantCaptureMouse;
}

bool zpk3ImGuiWantCaptureKeyboard(void) {
    return ImGui::GetIO().WantCaptureKeyboard;
}

void zpk3ImGuiSetNextWindowSize(float width, float height) {
    ImGui::SetNextWindowSize(ImVec2(width, height), ImGuiCond_FirstUseEver);
}

void zpk3ImGuiSetNextWindowPos(float x, float y) {
    ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_FirstUseEver);
}

void zpk3ImGuiSetNextWindowCollapsed(bool collapsed) {
    ImGui::SetNextWindowCollapsed(collapsed, ImGuiCond_FirstUseEver);
}

bool zpk3ImGuiBeginWindow(const char *title, bool *open) {
    return ImGui::Begin(title, open);
}

void zpk3ImGuiEndWindow(void) {
    ImGui::End();
}

void zpk3ImGuiText(const char *text) {
    ImGui::TextUnformatted(text);
}

void zpk3ImGuiSeparator(void) {
    ImGui::Separator();
}

void zpk3ImGuiSameLine(void) {
    ImGui::SameLine();
}

bool zpk3ImGuiCheckbox(const char *label, bool *value) {
    return ImGui::Checkbox(label, value);
}

bool zpk3ImGuiButton(const char *label) {
    return ImGui::Button(label);
}

bool zpk3ImGuiSelectable(const char *label, bool selected) {
    return ImGui::Selectable(label, selected);
}

void zpk3ImGuiBeginChild(const char *id, float width, float height, bool border) {
    ImGui::BeginChild(id, ImVec2(width, height), border);
}

void zpk3ImGuiEndChild(void) {
    ImGui::EndChild();
}

}
