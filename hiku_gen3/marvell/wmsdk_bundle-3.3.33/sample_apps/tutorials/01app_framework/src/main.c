/*
 *  Copyright (C) 2008-2016 Marvell International Ltd.
 *  All Rights Reserved.
 */
/* Tutorial 1: Application Framework
 *
 * Use the Application Framework to start the Wi-Fi station interface. The
 * station interface reads the network information that is configured in the PSM
 * and connects to it.
 */
#include <wmstdio.h>
#include <cli.h>
#include <psm.h>
#include <app_framework.h>

/* Handle Critical Error Handlers */
void critical_error_handler(void *data)
{
	while (1)
		;
	/* do nothing -- stall */
}

/*
 * Handler invoked on WLAN_INIT_DONE event.
 */
static void event_wlan_init_done(void *data)
{
	/* We receive provisioning status in data */
	int provisioned = (int)data;

	wmprintf("Event: WLAN_INIT_DONE provisioned=%d\r\n", provisioned);

	if (provisioned) {
		wmprintf("Starting station\r\n");
		app_sta_start();
	} else {
		wmprintf("Not provisioned\r\n");
	}

}
/* This is the main event handler for this project. The application framework
 * calls this function in response to the various events in the system.
 */
int common_event_handler(int event, void *data)
{
	switch (event) {
	case AF_EVT_WLAN_INIT_DONE:
		event_wlan_init_done(data);
		break;
	default:
		break;
	}

	return WM_SUCCESS;
}

int main()
{
	wmstdio_init(UART0_ID, 0);

	cli_init();

	psm_cli_init();


	if (app_framework_start(common_event_handler) != WM_SUCCESS) {
		wmprintf("Failed to start application framework");
		critical_error_handler((void *) -WM_FAIL);
	}

	return 0;
}
