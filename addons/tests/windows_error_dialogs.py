import os
import ctypes


_SUPPRESSED = False


def suppress_windows_error_dialogs() -> None:
    """Prevent benchmark child crashes from blocking unattended runs with UI."""
    global _SUPPRESSED
    if _SUPPRESSED or os.name != "nt":
        return

    sem_failcriticalerrors = 0x0001
    sem_nogpfault_error_box = 0x0002
    sem_noopenfile_error_box = 0x8000
    flags = sem_failcriticalerrors | sem_nogpfault_error_box | sem_noopenfile_error_box

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.SetErrorMode.argtypes = [ctypes.c_uint]
    kernel32.SetErrorMode.restype = ctypes.c_uint
    previous = int(kernel32.SetErrorMode(0))
    kernel32.SetErrorMode(previous | flags)
    _SUPPRESSED = True
