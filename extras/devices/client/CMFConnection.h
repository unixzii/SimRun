#import <Foundation/Foundation.h>

typedef void (^CMFMessageHandler)(NSDictionary *message);
typedef void (^CMFStateHandler)(BOOL connected);

void CMFConnectionSetMessageHandler(CMFMessageHandler handler);
void CMFConnectionSetStateHandler(CMFStateHandler handler);
void CMFConnectionSend(NSDictionary *msg);
void CMFConnectionOpen(void);
BOOL CMFConnectionIsConnected(void);
