import subprocess
import sys

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
MAIN_SCENE = "res://modules/world_player_v2/world_testV2.tscn"
TIMEOUT = 60  # 30s wait + 15s test = 45s, buffer for safety
BOT_SCENE = "res://tests/player_bot.tscn"  # Bot scene to add
def main():
    print("🤖 Running Movement Bot Test...")
    print(f"   Scene: {MAIN_SCENE}")
    print("-" * 50)
    
    cmd = [
        GODOT_BIN,
        "--path", PROJECT_PATH,
        MAIN_SCENE
    ]
    
    try:
        result = subprocess.run(
            cmd, 
            capture_output=True, 
            text=True, 
            timeout=TIMEOUT,
            encoding='utf-8',
            errors='replace'
        )
        output = result.stdout + "\n" + result.stderr
    except subprocess.TimeoutExpired as e:
        print(f"⚠️  Timeout after {TIMEOUT}s (bot may still be running)")
        output = (e.stdout if e.stdout else "") + "\n" + (e.stderr if e.stderr else "")
    except Exception as e:
        print(f"❌ Error: {e}")
        return 1
    
    # Show all output for debugging
    print("\n" + "=" * 50)
    print("FULL OUTPUT:")
    print("=" * 50)
    print(output)
    print("=" * 50)
    
    # Filter for bot and hotbar debug output
    print("\nBOT & HOTBAR DEBUG:")
    print("=" * 50)
    
    bot_found = False
    for line in output.splitlines():
        if "[BOT]" in line or "[HOTBAR_DEBUG]" in line or "[QUICKLOAD_TEST]" in line or "[ROUTER_DEBUG]" in line or "[COMBAT_DEBUG]" in line or "[QUICKLOAD_FALL_TEST]" in line or "[TERRAIN_PERSIST_TEST]" in line or "[COMPLEX_TERRAIN_TEST]" in line or "[TERRAIN_MINING]" in line or "[SAVE_NOTIFICATION]" in line or "[LOAD_NOTIFICATION]" in line or "[HUD_SETUP]" in line or "[HUD_NOTIF_TEST]" in line or "[ZOMBIE_TEST]" in line or "[ZOMBIE_COUNT_TEST]" in line:
            print(line)
            bot_found = True
    
    if not bot_found:
        print("(No bot or debug output found)")
    
    print("=" * 50)
    return 0

if __name__ == "__main__":
    sys.exit(main())
