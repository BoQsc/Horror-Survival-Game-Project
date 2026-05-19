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
    _suppress_windows_error_reporting_ui()
    _SUPPRESSED = True


def _suppress_windows_error_reporting_ui() -> None:
    # Some Windows builds route crash UI through WER even when the process error
    # mode is set. This is best-effort because the symbol availability varies.
    wer_fault_reporting_no_ui = 0x20
    for dll_name in ("kernel32", "wer"):
        try:
            dll = ctypes.WinDLL(dll_name, use_last_error=True)
            wer_set_flags = dll.WerSetFlags
        except (AttributeError, OSError):
            continue
        wer_set_flags.argtypes = [ctypes.c_uint]
        wer_set_flags.restype = ctypes.c_long
        wer_set_flags(wer_fault_reporting_no_ui)
        return
