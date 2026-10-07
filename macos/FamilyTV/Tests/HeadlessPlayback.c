/* Synthetic-video tests use the same bundled libVLC via its public C API.
 * The vmem callbacks prove that frames decode without requiring a runner GPU. */
#import <VLCKit/VLCKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>

typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_media_t libvlc_media_t;
typedef struct libvlc_media_player_t libvlc_media_player_t;
extern void libvlc_release(libvlc_instance_t *);
extern void libvlc_retain(libvlc_instance_t *);
extern libvlc_media_t *libvlc_media_new_location(libvlc_instance_t *, const char *);
extern void libvlc_media_add_option(libvlc_media_t *, const char *);
extern void libvlc_media_release(libvlc_media_t *);
extern libvlc_media_player_t *libvlc_media_player_new(libvlc_instance_t *);
extern void libvlc_media_player_set_media(libvlc_media_player_t *, libvlc_media_t *);
extern int libvlc_media_player_play(libvlc_media_player_t *);
extern int libvlc_media_player_is_playing(libvlc_media_player_t *);
extern void libvlc_media_player_set_pause(libvlc_media_player_t *, int);
extern void libvlc_media_player_set_position(libvlc_media_player_t *, float);
extern int libvlc_media_player_is_seekable(libvlc_media_player_t *);
extern void libvlc_media_player_stop(libvlc_media_player_t *);
extern void libvlc_media_player_release(libvlc_media_player_t *);
extern void libvlc_video_set_callbacks(libvlc_media_player_t *, void *(*)(void *,void **), void (*)(void *,void *,void *const *),void (*)(void *,void *),void *);
extern void libvlc_video_set_format(libvlc_media_player_t *,const char *,unsigned,unsigned,unsigned);

static uint8_t pixels[320 * 180 * 4] __attribute__((aligned(64)));
static atomic_int frames;
static void *lock_frame(void *opaque, void **planes) { (void)opaque; *planes = pixels; return NULL; }
static void display_frame(void *opaque, void *picture) { (void)opaque; (void)picture; atomic_fetch_add(&frames,1); }
static int load(libvlc_instance_t *instance, libvlc_media_player_t *player, const char *uri) {
    libvlc_media_player_stop(player);
    atomic_store(&frames,0);
    libvlc_media_t *media=libvlc_media_new_location(instance,uri);
    if (!media) return 1;
    libvlc_media_add_option(media,"avcodec-hw=none");
    libvlc_media_add_option(media,"network-caching=500");
    libvlc_media_player_set_media(player,media);
    libvlc_media_release(media);
    if (libvlc_media_player_play(player)) return 1;
    for (int i=0;i<200;++i) { if(atomic_load(&frames)>=3) return 0; usleep(100000); }
    return 1;
}
int main(int argc, char **argv) {
 @autoreleasepool {
    (void)argv;
    const char *base=getenv("FAMILYTV_TEST_AUTH_BASE_URL");
    const char *probe=getenv("FAMILYTV_TEST_PROBE_URL");
    VLCLibrary *library=[[VLCLibrary alloc] initWithOptions:@[@"--quiet",@"--no-audio",@"--no-interact",@"--avcodec-hw=none",@"--vout=vmem"]];
    libvlc_instance_t *instance=(libvlc_instance_t *)library.instance;
    if(!instance){fprintf(stderr,"FAIL: libVLC initialization\n");return 1;}
    libvlc_retain(instance);
    libvlc_media_player_t *player=libvlc_media_player_new(instance);
    if(!player){fprintf(stderr,"FAIL: libVLC player initialization\n");return 1;}
    libvlc_video_set_callbacks(player,lock_frame,NULL,display_frame,NULL);
    libvlc_video_set_format(player,"RV32",320,180,320*4);
    if (probe) {
        int result=load(instance,player,probe);
        printf("LIVE PROBE: decoded frames=%d result=%s\n",atomic_load(&frames),result?"no video":"video decoded");
        libvlc_media_player_stop(player);libvlc_media_player_release(player);libvlc_release(instance);return result;
    }
    if(!base || argc<3)return 1;
    char uri[4096];
    snprintf(uri,sizeof(uri),"%s/dav/sample.mp4",base);
    if(load(instance,player,uri)){fprintf(stderr,"FAIL: authenticated H.264 MP4 decode\n");return 1;}
    if(!libvlc_media_player_is_seekable(player)){fprintf(stderr,"FAIL: VOD seek unavailable\n");return 1;}
    libvlc_media_player_set_position(player,0.3f);
    libvlc_media_player_set_pause(player,1);usleep(300000);
    if(libvlc_media_player_is_playing(player)){fprintf(stderr,"FAIL: pause\n");return 1;}
    libvlc_media_player_set_pause(player,0);
    snprintf(uri,sizeof(uri),"%s/dav/sample.m3u8",base);
    if(load(instance,player,uri)){fprintf(stderr,"FAIL: authenticated HLS decode\n");return 1;}
    if(load(instance,player,uri)){fprintf(stderr,"FAIL: HLS retry\n");return 1;}
    snprintf(uri,sizeof(uri),"%s/dav/dirty.m3u8",base);
    if(load(instance,player,uri)){fprintf(stderr,"FAIL: damaged TS recovery\n");return 1;}
    libvlc_media_player_stop(player);
    if(libvlc_media_player_is_playing(player)){fprintf(stderr,"FAIL: stop\n");return 1;}
    libvlc_media_player_release(player);libvlc_release(instance);
    printf("PASS: libVLC H.264 frames, WebDAV, HLS children, damaged TS recovery, seek, pause, stop, retry\n");
    return 0;
}
}
