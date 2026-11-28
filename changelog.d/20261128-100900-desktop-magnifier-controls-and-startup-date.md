type: Fixed

**Desktop magnifier controls, proportional panning, startup Auto appearance, and VM display pacing.** Fixed magnifier viewport panning in physical pixels so the pointer stays aligned across all edges and corners, added a floating `Magnifier` control bar (`-`, `+`, `Off`) plus `Ctrl+Shift+-`/`=`/`0` shortcuts, published the initial RTC date before sub-second edge alignment so `Auto` appearance applies immediately at boot, and enabled OpenGL SDL presentation (`-display sdl,gl=on`) for interactive `modustool run` VMs.
