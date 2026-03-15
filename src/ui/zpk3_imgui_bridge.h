#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void zpk3ImGuiSetup(bool dark_theme);
void zpk3ImGuiBegin(void);
void zpk3ImGuiEnd(void);
void zpk3ImGuiShutdown(void);

bool zpk3ImGuiWantCaptureMouse(void);
bool zpk3ImGuiWantCaptureKeyboard(void);

void zpk3ImGuiSetNextWindowSize(float width, float height);
bool zpk3ImGuiBeginWindow(const char *title, bool *open);
void zpk3ImGuiEndWindow(void);

void zpk3ImGuiText(const char *text);
void zpk3ImGuiSeparator(void);
void zpk3ImGuiSameLine(void);
bool zpk3ImGuiCheckbox(const char *label, bool *value);
bool zpk3ImGuiButton(const char *label);
bool zpk3ImGuiSelectable(const char *label, bool selected);
void zpk3ImGuiBeginChild(const char *id, float width, float height, bool border);
void zpk3ImGuiEndChild(void);

#ifdef __cplusplus
}
#endif
