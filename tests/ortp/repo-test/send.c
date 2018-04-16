  /*
  The oRTP library is an RTP (Realtime Transport Protocol - rfc3550) stack.
  Copyright (C) 2001  Simon MORLAT simon.morlat@linphone.org

  This library is free software; you can redistribute it and/or
  modify it under the terms of the GNU Lesser General Public
  License as published by the Free Software Foundation; either
  version 2.1 of the License, or (at your option) any later version.

  This library is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  Lesser General Public License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with this library; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/
#define ORTP_INET6
#include <ortp/ortp.h>
#include <signal.h>
#include <stdlib.h>

#include <sys/types.h>
#include <sys/time.h>
#include <stdio.h>

int runcond=1;

void stophandler(int signum)
{
        runcond=0;
}

int rtp_session_rtp_send (RtpSession * session, mblk_t * m);

mblk_t *rtcp_create_simple_bye_packet(uint32_t ssrc, const char *reason);
int rtp_session_rtcp_send (RtpSession * session, mblk_t * m);

static const char *help="usage: rtpsend filename dest_ip4addr dest_port [ --with-clockslide <value> ] [ --with-jitter <milliseconds>]\n";


int rtp_send(RtpSession * session, mblk_t *mp, uint32_t packet_ts){
	rtp_header_t *rtp;
	rtp=(rtp_header_t*)mp->b_rptr;
	rtp->timestamp=packet_ts;
	session->rtp.snd_seq=rtp->seq_number+1;
	int error = rtp_session_rtp_send (session, mp);
	return error;
}

int main(int argc, char *argv[])
{
        RtpSession *session;
        unsigned char buffer[]  = "Hello World";
        int i;
        char *ssrc;
        uint32_t user_ts=0;
        int clockslide=0;
        int jitter=0;
        if (argc<3){
                printf("%s", help);
                return -1;
        }
        ortp_init();
        ortp_scheduler_init();
        ortp_set_log_level_mask(ORTP_MESSAGE|ORTP_WARNING|ORTP_ERROR);
        session=rtp_session_new(RTP_SESSION_SENDONLY);

//	rtp_session_enable_rtcp(session,0);
        rtp_session_set_blocking_mode(session,1);
        rtp_session_set_scheduling_mode(session,1);
        rtp_session_set_connected_mode(session,TRUE);
        rtp_session_set_remote_addr(session,argv[1],atoi(argv[2]));
        rtp_session_set_payload_type(session,0);
	rtp_session_enable_rtcp(session,1);

        ssrc=getenv("SSRC");
        if (ssrc!=NULL) {
                printf("using SSRC=%i.\n",atoi(ssrc));
                rtp_session_set_ssrc(session,atoi(ssrc));
        }

        signal(SIGINT,stophandler);

        while( (runcond) ) {
		usleep(10000);
                user_ts+=160;
                if (user_ts%(160*50)==0){
			ortp_message("sending RTCP bye");
			mblk_t *cm;
			mblk_t *sdes = NULL;
			mblk_t *bye = NULL;

			/* Make a BYE packet (will be on the end of the compund packet). */
			char reason[] = "I'm out";
			bye = rtcp_create_simple_bye_packet(session->snd.ssrc, reason);
			cm=bye;

			/* Send compound packet. */
			int ret = rtp_session_rtcp_send(session, cm);
			printf("ret: %d\n",ret);
                }
		mblk_t *m;
		m = rtp_session_create_packet(session,RTP_FIXED_HEADER_SIZE,(uint8_t*)buffer,sizeof(buffer)-1);
		rtp_send(session, m, 1234);
        }

        rtp_session_destroy(session);
        ortp_exit();
        ortp_global_stats_display();

        return 0;
}

