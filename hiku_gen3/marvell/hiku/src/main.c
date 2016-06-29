/*
 * main.c
 *
 *  Created on: Apr 27, 2016
 *      Author: rajan-work
 */

#include "hiku_common.h"
#include "connection_manager.h"
#include "ota_update.h"
#include "button_manager.h"
#include "hiku_board.h"

extern unsigned long _bss1;
extern unsigned long _ebss1;

int main()
{

	memset(&_bss1, 0x00, ((unsigned)&_ebss1 - (unsigned)&_bss1));

	/* Initialize console on uart0 */
	wmstdio_init(UART0_ID, 0);
	hiku_m("Initializing hiku!!\r\n");

	if (connection_manager_init() != WM_SUCCESS )
	{
		hiku_m("Failed to initialize Connection Manager!!\r\n");
		return -WM_FAIL;
	}

	if (hiku_board_init() != WM_SUCCESS )
	{
		hiku_m("Failed to initalize hiku Board Init!\r\n");
		return -WM_FAIL;
	}

	if (ota_update_init() != WM_SUCCESS)
	{
		hiku_m("Failed to initialize OTA Update Manager!!\r\n");
		return -WM_FAIL;
	}

	if (button_manager_init() != WM_SUCCESS)
	{
		hiku_m("Failed to initialize Button Manager!!\r\n");
		return -WM_FAIL;
	}

	hiku_m("Successfully initialized hiku!!\r\n");
	return WM_SUCCESS;
}


