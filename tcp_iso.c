#include "tcp_iso.h"


//void TCP_BOK(TPSVCINFO *msg)
void TCP_ISO(TPSVCINFO *msg)
{
  int     rc;
  char    SndStationName[64];


  ulog( _FLOW_, "[%s] from TPmsg (msg->len : %d)", FF, msg->len );

  memset( SndStationName, 0x00, sizeof(SndStationName) );
  tpgetsndsvc( SndStationName, NULL );

  roTrace( 'I', SndStationName, msg->len, (unsigned char*)msg->data );

  rc = lf_SendMessage( msg->data, msg->len );
  if( rc < 0 ) {
    ulog( _ERROR_, "lf_SendMessage() Fail. (rc:%d/len:%d)", rc, msg->len );
    tpreturn_r( TPFAIL, -1, NULL, 0, 0 );
    return;
  }

  tpreturn_r( TPSUCCESS, 0, NULL, 0, 0 );

  return;
}

