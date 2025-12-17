import os
import urllib.request
import zipfile
import subprocess
import sys
import shutil

# Configuration
GODOT_CPP_URL = "https://github.com/godotengine/godot-cpp/archive/refs/tags/godot-4.5-stable.zip"
ZIG_URL = "https://ziglang.org/builds/zig-x86_64-windows-0.16.0-dev.1484+d0ba6642b.zip"

GODOT_CPP_DIR_NAME = "godot-cpp-godot-4.5-stable"
ZIG_DIR_NAME = "zig-x86_64-windows-0.16.0-dev.1484+d0ba6642b"

def download_and_extract(url, target_name):
    filename = url.split('/')[-1]
    
    # Check if directory already exists
    if os.path.exists(target_name):
        print(f"Directory '{target_name}' already exists. Skipping download.")
        return

    print(f"Downloading {filename}...")
    try:
        urllib.request.urlretrieve(url, filename)
    except Exception as e:
        print(f"Error downloading {url}: {e}")
        sys.exit(1)

    print(f"Extracting {filename}...")
    try:
        with zipfile.ZipFile(filename, 'r') as zip_ref:
            zip_ref.extractall(".")
    except Exception as e:
        print(f"Error extracting {filename}: {e}")
        sys.exit(1)
        
    # Cleanup zip file
    if os.path.exists(filename):
        os.remove(filename)
    print(f"Successfully setup {target_name}")

def install_scons():
    print("Installing/Upgrading SCons via pip...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "scons"])
    except subprocess.CalledProcessError as e:
        print(f"Error installing SCons: {e}")
        sys.exit(1)

def create_source_files():
    print("Creating source files...")
    src_dir = os.path.join("testextension", "src")
    if not os.path.exists(src_dir):
        os.makedirs(src_dir)

    # plain string content for files
    gdexample_h = """#ifndef GDEXAMPLE_H
#define GDEXAMPLE_H

#include <godot_cpp/classes/sprite2d.hpp>

namespace godot {

class GDExample : public Sprite2D {
    GDCLASS(GDExample, Sprite2D)

private:
    double time_passed;

protected:
    static void _bind_methods();

public:
    GDExample();
    ~GDExample();

    void _process(double delta) override;
};

}

#endif
"""

    gdexample_cpp = """#include "gdexample.h"
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void GDExample::_bind_methods() {
}

GDExample::GDExample() {
    time_passed = 0.0;
}

GDExample::~GDExample() {
}

void GDExample::_process(double delta) {
    time_passed += delta;
    
    Vector2 new_position = Vector2(10.0 + (10.0 * sin(time_passed * 2.0)), 10.0 + (10.0 * cos(time_passed * 1.5)));
    
    set_position(new_position);
}
"""

    register_types_h = """#ifndef GD_EXAMPLE_REGISTER_TYPES_H
#define GD_EXAMPLE_REGISTER_TYPES_H

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_example_module(ModuleInitializationLevel p_level);
void uninitialize_example_module(ModuleInitializationLevel p_level);

#endif // GD_EXAMPLE_REGISTER_TYPES_H
"""

    register_types_cpp = """#include "register_types.h"

#include "gdexample.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_example_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    ClassDB::register_class<GDExample>();
}

void uninitialize_example_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
// Initialization.
GDExtensionBool GDE_EXPORT example_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_example_module);
    init_obj.register_terminator(uninitialize_example_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
"""

    with open(os.path.join(src_dir, "gdexample.h"), "w") as f:
        f.write(gdexample_h)
    with open(os.path.join(src_dir, "gdexample.cpp"), "w") as f:
        f.write(gdexample_cpp)
    with open(os.path.join(src_dir, "register_types.h"), "w") as f:
        f.write(register_types_h)
    with open(os.path.join(src_dir, "register_types.cpp"), "w") as f:
        f.write(register_types_cpp)

def create_sconstruct():
    print("Creating SConstruct...")
    
    sconstruct_content = """#!/usr/bin/env python
import os
import sys

env = SConscript("godot-cpp-godot-4.5-stable/SConstruct")

# Get the directory where scons is running (the project root)
project_path = os.getcwd()
zig_exe = os.path.join(project_path, "zig-x86_64-windows-0.16.0-dev.1484+d0ba6642b", "zig.exe")

# Configure Zig as the compiler
env["CC"] = zig_exe + " cc"
env["CXX"] = zig_exe + " c++"
env["LINK"] = zig_exe + " c++"
env["RANLIB"] = zig_exe + " ranlib"

# Use temp files for sources to avoid "command line too long"
if sys.platform == "win32":
    env["ARCOM"] = zig_exe + " ar $ARFLAGS $TARGET ${TEMPFILE('$SOURCES')}"
    env["LINKCOM"] = zig_exe + " c++ $LINKFLAGS -o $TARGET ${TEMPFILE('$SOURCES')} $SHLINKFLAGS"
else:
    env["AR"] = zig_exe + " ar"
    env["LINK"] = zig_exe + " c++"

# Fix for "App Data Dir Unavailable"
zig_cache = os.path.join(project_path, "zig_cache")
if not os.path.exists(zig_cache):
    os.makedirs(zig_cache)

env["ENV"]["ZIG_GLOBAL_CACHE_DIR"] = zig_cache
env["ENV"]["ZIG_LOCAL_CACHE_DIR"] = zig_cache

# Sources
sources = Glob("testextension/src/*.cpp")

if env["platform"] == "macos":
    library = env.SharedLibrary(
        "testextension/bin/gdexample.{}.{}.framework/gdexample.{}.{}".format(
            env["platform"], env["target"], env["platform"], env["target"]
        ),
        source=sources,
    )
else:
    library = env.SharedLibrary(
        "testextension/bin/gdexample{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
        source=sources,
    )

Default(library)
"""
    with open("SConstruct", "w") as f:
        f.write(sconstruct_content)


def create_project_file():
    print("Creating project.godot...")
    # Create testextension directory if it doesn't exist (though create_source_files creates src inside it)
    if not os.path.exists("testextension"):
        os.makedirs("testextension")
        
    content = """; Engine configuration file.
; It's best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=5

[application]

config/name="ZigGDExtension"
config/features=PackedStringArray("4.3", "Forward Plus")
config/icon="res://icon.svg"

[display]

window/size/viewport_width=1152
window/size/viewport_height=648

[dotnet]

project/assembly_name="ZigGDExtension"
"""
    with open(os.path.join("testextension", "project.godot"), "w") as f:
        f.write(content)

def create_extension_config():
    print("Creating extension config...")
    bin_dir = os.path.join("testextension", "bin")
    if not os.path.exists(bin_dir):
        os.makedirs(bin_dir)

    content = """[configuration]

entry_symbol = "example_library_init"
compatibility_minimum = 4.1

[libraries]

windows.debug.x86_64 = "res://bin/gdexample.windows.template_debug.x86_64.dll"
windows.release.x86_64 = "res://bin/gdexample.windows.template_release.x86_64.dll"
"""
    with open(os.path.join(bin_dir, "example.gdextension"), "w") as f:
        f.write(content)

def run_build():
    print("Running SCons build...")
    try:
        # Run scons to build the extension
        subprocess.check_call([sys.executable, "-m", "SCons", "--jobs=4"])
    except subprocess.CalledProcessError as e:
        print(f"Error during build: {e}")
        sys.exit(1)

def main():
    print("Starting Setup...")
    install_scons()
    download_and_extract(GODOT_CPP_URL, GODOT_CPP_DIR_NAME)
    download_and_extract(ZIG_URL, ZIG_DIR_NAME)
    create_source_files()
    create_sconstruct()
    create_project_file()
    create_extension_config()
    run_build()
    print("Setup and Build Complete! You can now open 'project.godot' in Godot to verify.")

if __name__ == "__main__":
    main()
