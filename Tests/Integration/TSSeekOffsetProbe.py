import ctypes as C
from pathlib import Path
import json,time,hashlib
root=Path(__file__).resolve().parents[2]
libpath=root/'dist/SiliconPlayer.app/Contents/Frameworks/libmpv.2.dylib'
mpv=C.CDLL(str(libpath))
class Event(C.Structure):
 _fields_=[('event_id',C.c_int),('error',C.c_int),('reply_userdata',C.c_uint64),('data',C.c_void_p)]
mpv.mpv_create.restype=C.c_void_p
mpv.mpv_set_option_string.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p]
mpv.mpv_set_property_string.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p]
mpv.mpv_initialize.argtypes=[C.c_void_p]
mpv.mpv_command.argtypes=[C.c_void_p,C.POINTER(C.c_char_p)]
mpv.mpv_wait_event.argtypes=[C.c_void_p,C.c_double];mpv.mpv_wait_event.restype=C.POINTER(Event)
mpv.mpv_get_property.argtypes=[C.c_void_p,C.c_char_p,C.c_int,C.c_void_p]
mpv.mpv_get_property_string.argtypes=[C.c_void_p,C.c_char_p];mpv.mpv_get_property_string.restype=C.c_void_p
mpv.mpv_free.argtypes=[C.c_void_p];mpv.mpv_terminate_destroy.argtypes=[C.c_void_p]
def cmd(h,*args):
 a=(C.c_char_p*(len(args)+1))(*(str(v).encode() for v in args),None)
 rc=mpv.mpv_command(h,a)
 if rc<0: raise RuntimeError((args,rc))
def prop(h,name):
 v=C.c_double();rc=mpv.mpv_get_property(h,name.encode(),5,C.byref(v))
 return v.value if rc>=0 else None
def textprop(h,name):
 ptr=mpv.mpv_get_property_string(h,name.encode())
 if not ptr:return None
 val=C.string_at(ptr).decode();mpv.mpv_free(ptr);return val
def wait(h,event_id):
 end=time.monotonic()+10
 while time.monotonic()<end:
  e=mpv.mpv_wait_event(h,.1).contents
  if e.event_id==event_id:return
  if e.event_id==7 and e.error<0:raise RuntimeError(('load failure',e.error))
 raise RuntimeError(('event timeout',event_id))
results=[]
for fixture in ['mpeg2-ts-mp2.ts','mpeg2-anamorphic.ts']:
 media=root/'Tests/Fixtures/ExpandedMedia'/fixture
 for offset in [0,.5,1,2]:
  h=mpv.mpv_create()
  try:
   for k,v in {'vo':'null','ao':'null','hwdec':'no','config':'no','pause':'yes','keep-open':'yes','hr-seek-demuxer-offset':str(offset)}.items():
    assert mpv.mpv_set_option_string(h,k.encode(),v.encode())>=0
   assert mpv.mpv_initialize(h)>=0
   cmd(h,'loadfile',str(media));wait(h,8);wait(h,21)
   seeks=[]
   for target in [2,3,12,4,.1,20]:
    cmd(h,'seek',target,'absolute+exact');wait(h,21)
    seeks.append({'target':target,'actual':prop(h,'time-pos')})
   results.append({'fixture':fixture,'sha256':hashlib.sha256(media.read_bytes()).hexdigest(),'offset':offset,'fileFormat':textprop(h,'file-format'),'demuxer':textprop(h,'demuxer'),'seeks':seeks})
   print(results[-1],flush=True)
  finally:mpv.mpv_terminate_destroy(h)
folder=root/'Docs/IncrementalTest-2026-10-04/ts-seek'
folder.mkdir(parents=True,exist_ok=True)
(folder/'offset-probe.json').write_text(json.dumps({'scope':'Exact bundled libmpv with null output; actual application regression still required','librarySHA256':hashlib.sha256(libpath.read_bytes()).hexdigest(),'results':results},ensure_ascii=False,indent=2)+'\n')
