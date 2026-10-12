/* Standalone streaming SPCM -> sherpa-onnx C API service; draft, not executed. */
#include <sherpa-onnx/c-api/c-api.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/task_info.h>

#define HEADER 112
#define CHUNK 320
#define RATE 16000
#define LINE_BOUND 262144
#define TEXT_BOUND 16384
#define TOKEN_BOUND 4096
#define SAMPLE_BOUND (UINT64_C(16000) * 21600)
_Static_assert(sizeof(float) == 4, "SPCM Float32 required");
typedef struct {
  const SherpaOnnxOnlineRecognizer *recognizer;
  const SherpaOnnxOnlineStream *stream;
  uint64_t epoch, segment, item, accepted, padding, first_input_sequence, input_sequence, generation, revision, input_sample_bound;
  uint32_t stream_index;
  unsigned recognizers_created, recognizers_destroyed, streams_created, streams_destroyed;
  unsigned endpoint_resets;
  char last_text[TEXT_BOUND];
  int finished, failed, input_progress;
} State;
typedef struct { char bytes[LINE_BOUND]; size_t used; int ok; } Line;
static volatile sig_atomic_t stopped;
static uint64_t event_sequence, peak_footprint;
static double began, compute_seconds;
static double monotonic(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec+t.tv_nsec*1e-9; }
static void on_signal(int value) { (void)value; stopped = 1; }
static uint64_t footprint(void) {
  task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
  if (info.phys_footprint > peak_footprint) peak_footprint = info.phys_footprint;
  return info.phys_footprint;
}
static void append(Line *l, const char *format, ...) {
  if (!l->ok) return;
  va_list args; va_start(args, format); int n=vsnprintf(l->bytes+l->used, LINE_BOUND-l->used, format, args); va_end(args);
  if (n<0 || (size_t)n>=LINE_BOUND-l->used) { l->ok=0; return; }
  l->used+=(size_t)n;
}
static void quoted(Line *l, const char *s) {
  append(l,"\"");
  for (const unsigned char *p=(const unsigned char *)(s?s:""); *p && l->ok; ++p) {
    if (*p=='"' || *p=='\\') append(l,"\\%c",*p);
    else if (*p<32) append(l,"\\u%04x",*p);
    else append(l,"%c",*p);
  }
  append(l,"\"");
}
static Line prefix(State *s, const char *event) {
  Line l={.ok=1}; append(&l,"{\"sequence\":%" PRIu64 ",\"wall_seconds\":%.9f,\"event\":",++event_sequence,monotonic()-began); quoted(&l,event);
  append(&l,",\"epoch\":%" PRIu64 ",\"timing_segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"stream_index\":%u,\"stream_generation\":%" PRIu64 ",\"accepted_samples\":%" PRIu64 ",\"padding_samples\":%" PRIu64 ",\"first_input_sequence\":%" PRIu64 ",\"last_input_sequence\":%" PRIu64 ",\"live_recognizers\":%u,\"live_streams\":%u",
    s->epoch,s->segment,s->item,s->stream_index,s->generation,s->accepted,s->padding,s->first_input_sequence,s->input_sequence,
    s->recognizers_created-s->recognizers_destroyed,s->streams_created-s->streams_destroyed);
  if(s->input_progress)append(&l,",\"monotonic_seconds\":%.9f",monotonic());
  return l;
}
static int send_line(Line *l) {
  append(l,"}\n"); if (!l->ok) return 0;
  size_t sent=0; double deadline=monotonic()+3;
  while (sent<l->used) {
    ssize_t n=write(STDOUT_FILENO,l->bytes+sent,l->used-sent);
    if (n>0) {sent+=(size_t)n; continue;}
    if (n<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR) return 0;
    if (monotonic()>=deadline) return 0;
    struct pollfd fd={STDOUT_FILENO,POLLOUT,0}; poll(&fd,1,10);
  }
  return 1;
}
static int error(State *s, const char *reason) {
  s->failed=1; Line l=prefix(s,"error"); append(&l,",\"reason\":"); quoted(&l,reason); send_line(&l); return 0;
}
static int event(State *s, const char *name, const char *reason) {
  Line l=prefix(s,name); append(&l,",\"reason\":"); quoted(&l,reason);
  if (!send_line(&l)) {s->failed=1; return 0;} return 1;
}
static uint32_t u32(const unsigned char *p) {uint32_t n=0;for(int i=3;i>=0;--i)n=(n<<8)|p[i];return n;}
static uint64_t u64(const unsigned char *p) {uint64_t n=0;for(int i=7;i>=0;--i)n=(n<<8)|p[i];return n;}
/* 1 complete; 0 boundary EOF; 2 owned cancellation; -1 truncated/error. */
static int read_exact(unsigned char *buffer, size_t length, int boundary) {
  size_t done=0;
  while(done<length) {
    if(stopped)return 2;
    ssize_t n=read(STDIN_FILENO,buffer+done,length-done);
    if(n>0){done+=(size_t)n;continue;}
    if(!n)return !done&&boundary?0:-1;
    if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)return -1;
    struct pollfd fd={STDIN_FILENO,POLLIN,0};poll(&fd,1,20);
  }
  return 1;
}
static void release_stream(State *s) {
  if(s->stream){SherpaOnnxDestroyOnlineStream(s->stream);s->stream=NULL;++s->streams_destroyed;}
}
static int new_stream(State *s, uint64_t epoch,uint64_t segment,uint64_t item,uint32_t index) {
  release_stream(s); s->epoch=epoch;s->segment=segment;s->item=item;s->stream_index=index;
  s->accepted=0;s->padding=0;s->first_input_sequence=0;s->revision=0;s->last_text[0]=0;s->finished=0;++s->generation;
  s->stream=SherpaOnnxCreateOnlineStream(s->recognizer);
  if(!s->stream)return error(s,"stream_creation_failed");++s->streams_created;
  return event(s,"stream_created","new_actual_media_identity_or_timing_segment");
}
static int snapshot(State *s,const char *kind,int final,int force) {
  if(!s->stream||stopped)return 1;
  const SherpaOnnxOnlineRecognizerResult *r=SherpaOnnxGetOnlineStreamResult(s->recognizer,s->stream);
  if(!r)return error(s,"result_API_NULL");int ok=0;
  const char *text=r->text?r->text:"",*raw=r->json?r->json:"";
  size_t size=strnlen(text,TEXT_BOUND),raw_size=strnlen(raw,LINE_BOUND/2);
  if(size==TEXT_BOUND||raw_size==LINE_BOUND/2||r->count<0||r->count>TOKEN_BOUND)goto done;
  /* Fixed v1.13.8 AsJsonString has these unique top-level numeric fields.
     Host must independently parse engine_result_json and compare both fields.
     This is not a general parser for untrusted JSON or other engine versions. */
  const char *start_key=strstr(raw,"\"start_time\":");
  const char *segment_key=strstr(raw,"\"segment\":");
  if(!start_key||!segment_key||strstr(start_key+13,"\"start_time\":")||strstr(segment_key+10,"\"segment\":"))goto done;
  errno=0;char *end;double engine_start=strtod(start_key+13,&end);
  if(errno||end==start_key+13||!isfinite(engine_start)||engine_start<0||engine_start>21600)goto done;
  while(*end==' ')++end;if(*end!=',')goto done;
  errno=0;long engine_segment=strtol(segment_key+10,&end,10);
  if(errno||end==segment_key+10||engine_segment<0||engine_segment>1000000)goto done;
  while(*end==' ')++end;if(*end!=',')goto done;
  for(int i=0;i<r->count;++i) {
    if(!r->tokens_arr||!r->tokens_arr[i]||strnlen(r->tokens_arr[i],2048)==2048)goto done;
    if(r->timestamps&&(!isfinite(r->timestamps[i])||r->timestamps[i]<0))goto done;
  }
  int changed=strcmp(s->last_text,text)!=0;
  if(!changed&&!force){ok=1;goto done;}
  memcpy(s->last_text,text,size+1);++s->revision;
  Line l=prefix(s,kind);append(&l,",\"revision\":%" PRIu64 ",\"final\":%s,\"text_changed\":%s,\"input_finished\":%s,\"text\":",s->revision,final?"true":"false",changed?"true":"false",s->finished?"true":"false");quoted(&l,text);
  append(&l,",\"tokens\":[");for(int i=0;i<r->count;++i){if(i)append(&l,",");quoted(&l,r->tokens_arr[i]);}
  append(&l,"],\"timestamps\":");
  if(r->timestamps){append(&l,"[");for(int i=0;i<r->count;++i){if(i)append(&l,",");append(&l,"%.9g",r->timestamps[i]);}append(&l,"]");}else append(&l,"null");
  append(&l,",\"engine_result_json\":");quoted(&l,raw);
  append(&l,",\"engine_start_time_seconds\":%.9g,\"engine_segment\":%ld,\"recognizer_sample_origin\":0",engine_start,engine_segment);
  append(&l,",\"timestamp_scope\":\"raw_engine_stream_relative_requires_start_time_and_actual_SPCM_span_mapping\"");
  ok=send_line(&l);
done:
  SherpaOnnxDestroyOnlineRecognizerResult(r);
  return ok?1:error(s,"result_or_JSON_bound_failure");
}
static int decode(State *s,int allow_endpoint) {
  for(int i=0;i<10000;++i) {
    if(stopped)return 1;
    if(!SherpaOnnxIsOnlineStreamReady(s->recognizer,s->stream))return 1;
    double t=monotonic();SherpaOnnxDecodeOnlineStream(s->recognizer,s->stream);compute_seconds+=monotonic()-t;footprint();
    if(stopped)return 1;
    if(!snapshot(s,"partial",0,0))return 0;
    if(allow_endpoint&&SherpaOnnxOnlineStreamIsEndpoint(s->recognizer,s->stream)) {
      if(!snapshot(s,"endpoint_final",1,1))return 0;
      SherpaOnnxOnlineStreamReset(s->recognizer,s->stream);++s->endpoint_resets;s->last_text[0]=0;
      if(!event(s,"endpoint_reset","library_preserves_feature_buffer_and_real_start_time"))return 0;
    }
  }
  return error(s,"decode_ready_loop_bound");
}
static int accept(State *s,const unsigned char *header,const unsigned char *bytes) {
  uint32_t flags=u32(header+12),count=u32(header+96),input_rate=u32(header+100),index=u32(header+40);
  uint64_t epoch=u64(header+16),segment=u64(header+24),item=u64(header+32),sequence=u64(header+88);
  int64_t pts=(int64_t)u64(header+64),denominator=(int64_t)u64(header+72),delay=(int64_t)u64(header+80);
  if(flags&~7u||!epoch||!item||!sequence||sequence<=s->input_sequence||index>4096||!u32(header+44)||!u32(header+48)
    ||u32(header+52)!=RATE||count<1||count>CHUNK||input_rate<8000||input_rate>96000
    ||denominator!=(int64_t)input_rate*RATE||delay<0
    ||!!(flags&1)!=(pts!=INT64_MIN)||!!(flags&2)!=(pts!=INT64_MIN&&pts<0))return error(s,"SPCM_metadata_bounds");
  if(s->stream && epoch<s->epoch)return error(s,"stale_epoch_requires_parent_filter");
  if(s->stream && epoch==s->epoch && segment<s->segment)return error(s,"stale_timing_segment");
  if(!s->stream||epoch!=s->epoch||segment!=s->segment||item!=s->item||index!=s->stream_index) {
    if(!new_stream(s,epoch,segment,item,index))return 0;
  }
  if(s->accepted+count>s->input_sample_bound)return error(s,
    s->input_sample_bound==SAMPLE_BOUND?"stream_sample_bound_6hours":"recognition_window_sample_bound_120seconds");
  float pcm[CHUNK];memcpy(pcm,bytes,count*sizeof(float));
  for(uint32_t i=0;i<count;++i)if(!isfinite(pcm[i]))return error(s,"nonfinite_SPCM_waveform");
  if(!s->first_input_sequence)s->first_input_sequence=sequence;
  s->input_sequence=sequence;double t=monotonic();
  SherpaOnnxOnlineStreamAcceptWaveform(s->stream,RATE,pcm,(int32_t)count);
  compute_seconds+=monotonic()-t;s->accepted+=count;footprint();
  /* Optional real credit receipt, after the synchronous C API accept returned.
     Padding never enters accepted/input_sequence. Default event stream stays
     unchanged. A failed stdout write fails closed; it is not an inferred ACK. */
  if(s->input_progress && !event(s,"input_accepted","actual_C_API_accept_complete_record"))return 0;
  return decode(s,1);
}
static int finish_input(State *s) {
  if(!s->stream)return error(s,"no_actual_PCM_input");
  s->finished=1;
  if(!event(s,"tail_padding_started","explicit_1second_zeros_without_media_PTS"))return 0;
  float zeros[CHUNK]={0};
  for(int i=0;i<RATE/CHUNK&&!stopped;++i) {
    double t=monotonic();SherpaOnnxOnlineStreamAcceptWaveform(s->stream,RATE,zeros,CHUNK);
    compute_seconds+=monotonic()-t;s->padding+=CHUNK;
    if(!decode(s,0))return 0;
  }
  if(stopped)return 1;
  SherpaOnnxOnlineStreamInputFinished(s->stream);
  if(!decode(s,0)||!snapshot(s,"eof_final",1,1))return 0;
  return 1;
}
int main(int argc,char **argv) {
  const char *encoder=NULL,*decoder=NULL,*joiner=NULL,*tokens=NULL;State s={.input_sample_bound=SAMPLE_BOUND};int ok=0;
  began=monotonic();
  for(int i=1;i<argc;++i) {
    if(i+1>=argc)return 2;const char *name=argv[i],*value=argv[++i];
    if(!strcmp(name,"--encoder"))encoder=value;
    else if(!strcmp(name,"--decoder"))decoder=value;
    else if(!strcmp(name,"--joiner"))joiner=value;
    else if(!strcmp(name,"--tokens"))tokens=value;
    else if(!strcmp(name,"--input-progress") && !s.input_progress && !strcmp(value,"1"))s.input_progress=1;
    else if(!strcmp(name,"--max-input-samples") && s.input_sample_bound==SAMPLE_BOUND && !strcmp(value,"1920000"))s.input_sample_bound=UINT64_C(1920000);
    else return 2;
  }
  if(!encoder||!decoder||!joiner||!tokens)return 2;
  if(s.input_progress && s.input_sample_bound!=UINT64_C(1920000))return 2;
  struct sigaction action={0};action.sa_handler=on_signal;sigemptyset(&action.sa_mask);
  sigaction(SIGTERM,&action,NULL);sigaction(SIGINT,&action,NULL);sigaction(SIGPIPE,&action,NULL);
  if(fcntl(STDIN_FILENO,F_SETFL,fcntl(STDIN_FILENO,F_GETFL)|O_NONBLOCK)<0
    ||fcntl(STDOUT_FILENO,F_SETFL,fcntl(STDOUT_FILENO,F_GETFL)|O_NONBLOCK)<0)return 2;
  if(strcmp(SherpaOnnxGetVersionStr(),"1.13.8")){error(&s,"fixed_engine_version_required");goto done;}
  SherpaOnnxOnlineRecognizerConfig config={0};
  config.feat_config.sample_rate=RATE;config.feat_config.feature_dim=80;
  config.model_config.transducer.encoder=encoder;config.model_config.transducer.decoder=decoder;config.model_config.transducer.joiner=joiner;
  config.model_config.tokens=tokens;config.model_config.provider="cpu";config.model_config.num_threads=2;
  config.model_config.modeling_unit="cjkchar";config.decoding_method="greedy_search";
  config.enable_endpoint=1;config.rule1_min_trailing_silence=2.4f;config.rule2_min_trailing_silence=1.2f;config.rule3_min_utterance_length=15.0f;
  s.recognizer=SherpaOnnxCreateOnlineRecognizer(&config);
  if(!s.recognizer){error(&s,"recognizer_creation_failed");goto done;}++s.recognizers_created;footprint();
  if(!event(&s,"ready","fixed_local_CPU_engine_2threads_no_microphone"))goto done;
  for(uint64_t packets=0;packets<UINT64_C(1200000)&&!stopped;++packets) {
    unsigned char header[HEADER],payload[CHUNK*sizeof(float)];
    int read=read_exact(header,HEADER,1);
    if(read==2)break;
    if(read==0){ok=finish_input(&s);goto done;}
    if(read!=1){error(&s,"truncated_header_or_input_error");goto done;}
    uint32_t count=u32(header+96);
    if(memcmp(header,"SPCM",4)||header[4]!=1||header[5]!=0||header[6]!=HEADER||header[7]!=0
      ||count<1||count>CHUNK||u32(header+8)!=HEADER+count*sizeof(float)) {error(&s,"SPCM_framing");goto done;}
    read=read_exact(payload,count*sizeof(float),0);if(read==2)break;
    if(read!=1){error(&s,"truncated_PCM_payload");goto done;}
    if(!accept(&s,header,payload))goto done;
  }
  if(!stopped){error(&s,"packet_count_bound");goto done;}ok=1;
done:
  if(stopped&&!s.failed){ok=1;if(!event(&s,"cancel_acknowledged","owned_signal_between_synchronous_C_API_calls"))ok=0;}
  release_stream(&s);
  if(s.recognizer){SherpaOnnxDestroyOnlineRecognizer(s.recognizer);s.recognizer=NULL;++s.recognizers_destroyed;}
  if(s.failed)ok=0;footprint();
  Line l=prefix(&s,"closed");append(&l,",\"ok\":%s,\"cancelled\":%s,\"recognizers_created\":%u,\"recognizers_destroyed\":%u,\"streams_created\":%u,\"streams_destroyed\":%u,\"endpoint_resets\":%u,\"compute_seconds\":%.9f,\"peak_sampled_physical_footprint_bytes\":%" PRIu64 ",\"application_groups_added\":0",
    ok?"true":"false",stopped?"true":"false",s.recognizers_created,s.recognizers_destroyed,s.streams_created,s.streams_destroyed,s.endpoint_resets,compute_seconds,peak_footprint);
  if(!send_line(&l))ok=0;return ok?0:1;
}
