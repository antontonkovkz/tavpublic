"""Windows process launch: suspended, assigned to a kill-on-close Job, then resumed."""
import ctypes
from ctypes import wintypes as w
import msvcrt
import os
import subprocess
import threading

k = ctypes.WinDLL('kernel32', use_last_error=True)
SIZE = ctypes.c_size_t
HANDLE = w.HANDLE


class BasicLimits(ctypes.Structure):
    _fields_ = [('process_time', ctypes.c_longlong), ('job_time', ctypes.c_longlong),
                ('flags', w.DWORD), ('min_working', SIZE), ('max_working', SIZE),
                ('active', w.DWORD), ('affinity', SIZE), ('priority', w.DWORD), ('scheduling', w.DWORD)]


class IO(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in ('read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]


class ExtendedLimits(ctypes.Structure):
    _fields_ = [('basic', BasicLimits), ('io', IO), ('process_mem', SIZE),
                ('job_mem', SIZE), ('peak_process', SIZE), ('peak_job', SIZE)]


class Startup(ctypes.Structure):
    _fields_ = [('cb', w.DWORD), ('reserved', w.LPWSTR), ('desktop', w.LPWSTR), ('title', w.LPWSTR),
                ('x', w.DWORD), ('y', w.DWORD), ('xsize', w.DWORD), ('ysize', w.DWORD),
                ('xchars', w.DWORD), ('ychars', w.DWORD), ('fill', w.DWORD), ('flags', w.DWORD),
                ('show', w.WORD), ('reserved_size', w.WORD), ('reserved_ptr', ctypes.c_void_p),
                ('stdin', HANDLE), ('stdout', HANDLE), ('stderr', HANDLE)]


class ProcessInfo(ctypes.Structure):
    _fields_ = [('process', HANDLE), ('thread', HANDLE), ('pid', w.DWORD), ('tid', w.DWORD)]


def signature(name, restype, *args):
    f = getattr(k, name)
    f.restype, f.argtypes = restype, args
    return f


create_job = signature('CreateJobObjectW', HANDLE, ctypes.c_void_p, w.LPCWSTR)
set_job = signature('SetInformationJobObject', w.BOOL, HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD)
assign = signature('AssignProcessToJobObject', w.BOOL, HANDLE, HANDLE)
create_process = signature('CreateProcessW', w.BOOL, w.LPCWSTR, w.LPWSTR, ctypes.c_void_p,
                           ctypes.c_void_p, w.BOOL, w.DWORD, ctypes.c_void_p, w.LPCWSTR,
                           ctypes.POINTER(Startup), ctypes.POINTER(ProcessInfo))
resume = signature('ResumeThread', w.DWORD, HANDLE)
close = signature('CloseHandle', w.BOOL, HANDLE)
terminate_job = signature('TerminateJobObject', w.BOOL, HANDLE, w.UINT)
terminate_process = signature('TerminateProcess', w.BOOL, HANDLE, w.UINT)
wait = signature('WaitForSingleObject', w.DWORD, HANDLE, w.DWORD)
exit_code = signature('GetExitCodeProcess', w.BOOL, HANDLE, ctypes.POINTER(w.DWORD))
launch_lock = threading.Lock()


def checked(ok):
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())


class JobProcess:
    def __init__(self, argv, stdout, stderr):
        self.job, self.handle, self.returncode = None, None, None
        info = ProcessInfo()
        self.job = create_job(None, None)
        checked(self.job)
        try:
            limits = ExtendedLimits()
            limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            checked(set_job(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
            startup = Startup()
            startup.cb = ctypes.sizeof(startup)
            startup.flags = 0x100 | 1  # STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
            startup.show = 0
            # Serialize the brief inheritable-handle launch window between workers.
            with launch_lock, open(os.devnull, 'rb') as stdin:
                handles = [msvcrt.get_osfhandle(f.fileno()) for f in (stdin, stdout, stderr)]
                try:
                    for handle in handles:
                        os.set_handle_inheritable(handle, True)
                    startup.stdin, startup.stdout, startup.stderr = handles
                    command = ctypes.create_unicode_buffer(subprocess.list2cmdline(argv))
                    checked(create_process(argv[0], command, None, None, True,
                                           0x08000000 | 4, None, None, ctypes.byref(startup), ctypes.byref(info)))
                    self.handle, self.pid = info.process, info.pid
                finally:
                    for handle in handles:
                        os.set_handle_inheritable(handle, False)
            self.handle, self.pid = info.process, info.pid
            try:
                checked(assign(self.job, self.handle))
                if resume(info.thread) == 0xFFFFFFFF:
                    checked(False)
            except BaseException:
                terminate_process(self.handle, 1)
                raise
            finally:
                close(info.thread)
                info.thread = None
        except BaseException:
            if self.handle:
                terminate_process(self.handle, 1)
            if info.thread:
                close(info.thread)
            self.close()
            raise

    def poll(self):
        if self.returncode is None and wait(self.handle, 0) == 0:
            code = w.DWORD()
            checked(exit_code(self.handle, ctypes.byref(code)))
            self.returncode = code.value
        return self.returncode

    def wait(self):
        wait(self.handle, 0xFFFFFFFF)
        return self.poll()

    def kill(self):
        checked(terminate_job(self.job, 1))

    def close(self):
        if self.job:
            close(self.job)
            self.job = None
        if self.handle:
            close(self.handle)
            self.handle = None

    def __del__(self):
        self.close()
