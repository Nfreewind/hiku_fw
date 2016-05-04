/**
 * \file
 *
 * \brief OV7740 image sensor capture example.
 *
 * Copyright (c) 2014-2015 Atmel Corporation. All rights reserved.
 *
 * \asf_license_start
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. The name of Atmel may not be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * 4. This software may only be redistributed and used in connection with an
 *    Atmel microcontroller product.
 *
 * THIS SOFTWARE IS PROVIDED BY ATMEL "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT ARE
 * EXPRESSLY AND SPECIFICALLY DISCLAIMED. IN NO EVENT SHALL ATMEL BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 * \asf_license_stop
 *
 */

/**
 * \mainpage OV7740 image sensor capture example.
 *
 * \section Purpose
 *
 * This example demonstrates how to configure the OV7740 to capture a picture
 * and display it on LCD.
 *
 * \section Requirements
 *
 * This package can be used with sam4s_wpir_rd board.
 *
 * \section Description
 *
 * This example first sets the PLLB to the system core clock and PLLA to clock
 * PCK0 (used to get data from image sensor). Next step is to configure the
 * LCD controller and display information to the user. Then external SRAM, which
 * is used to store data after acquisition, is configured. Finally this example
 * configures the OV7740 CMOS image sensor and the PIO capture.
 * When the user presses the push button, a picture is captured, stored
 * to the external SRAM memory and finally displayed on the LCD.
 *
 * \section Usage
 *
 * -# Build the program and download it inside the evaluation board.
 *
 */
/*
 * Support and FAQ: visit <a href="http://www.atmel.com/design-support/">Atmel Support</a>
 */

/* Standard includes. */
#include <stdio.h>
#include "teststring.h"

/* Kernel includes. */
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "portmacro.h"

#include "croutine.h"
#include "list.h"
#include "mpu_wrappers.h"
#include "portable.h"
#include "projdefs.h"
#include "queue.h"
#include "semphr.h"
#include "StackMacros.h"
#include "timers.h"

#include "asf.h"
#include "conf_board.h"
#include "conf_clock.h"

#include "zbar.h"

//~~~~~~~~~~~~~~~~ Begin FreeRTOS specific definitions ~~~~~~~~~~~~~~~~~~~~

#define TASK_MONITOR_STACK_SIZE            (2048/sizeof(portSTACK_TYPE))
#define TASK_MONITOR_STACK_PRIORITY        (tskIDLE_PRIORITY)
#define TASK_LED_STACK_SIZE                (1024/sizeof(portSTACK_TYPE))
#define TASK_LED_STACK_PRIORITY            (tskIDLE_PRIORITY)

extern void vApplicationStackOverflowHook(xTaskHandle *pxTask,
signed char *pcTaskName);
extern void vApplicationIdleHook(void);
extern void vApplicationTickHook(void);
extern void xPortSysTickHandler(void);

SemaphoreHandle_t xDisplaySemaphore = NULL;
SemaphoreHandle_t xCameraSemaphore = NULL;

//~~~~~~~~~~~~~~~~ End FreeRTOS specific definitions ~~~~~~~~~~~~~~~~~~~~


//#define malloc(size) pvPortMalloc(size)
//#define calloc(size) pvPortCalloc(size)
//#define free(ptr) vPortFree(ptr)


#define RAWDATA  (0x63000000UL);
volatile uint8_t * g_zbar_raw_data = (uint8_t *)RAWDATA;
volatile uint8_t *g_zbar_raw_data_begin;

volatile uint8_t *tempend;

/* Uncomment this macro to work in black and white mode */
#define DEFAULT_MODE_COLORED

#ifndef PIO_PCMR_DSIZE_WORD
#  define PIO_PCMR_DSIZE_WORD PIO_PCMR_DSIZE(2)
#endif

/* TWI clock frequency in Hz (400KHz) */
#define TWI_CLK     (400000UL)

/* Pointer to the image data destination buffer */
uint8_t *g_p_uc_cap_dest_buf;

/* Rows size of capturing picture */
uint16_t g_us_cap_rows = IMAGE_HEIGHT;

/* Define display function and line size of captured picture according to the */
/* current mode (color or black and white) */
#ifdef DEFAULT_MODE_COLORED
	#define _display() draw_frame_yuv_color_int()

	/* (IMAGE_WIDTH *2 ) because ov7740 use YUV422 format in color mode */
	/* (draw_frame_yuv_color_int for more details) */
	uint16_t g_us_cap_line = (IMAGE_WIDTH * 2);
#else
	#define _display() draw_frame_yuv_bw8()

	uint16_t g_us_cap_line = (IMAGE_WIDTH);
#endif

/* Push button information (true if it's triggered and false otherwise) */
static volatile uint32_t g_ul_push_button_trigger = false;

/* Vsync signal information (true if it's triggered and false otherwise) */
static volatile uint32_t g_ul_vsync_flag = false;

/**
 * \brief Handler for vertical synchronisation using by the OV7740 image
 * sensor.
 */
static void vsync_handler(uint32_t ul_id, uint32_t ul_mask)
{
	unused(ul_id);
	unused(ul_mask);
	
	g_ul_vsync_flag = true;
	
	static signed portBASE_TYPE xHigherPriorityTaskWoken;
	xHigherPriorityTaskWoken = pdFALSE;
	xSemaphoreGiveFromISR(xCameraSemaphore, pdTRUE);
	portYIELD_FROM_ISR(xHigherPriorityTaskWoken);
	
}



/**
 * \brief Handler for button rising edge interrupt.
 */
static void button_handler(uint32_t ul_id, uint32_t ul_mask)
{
	unused(ul_id);
	unused(ul_mask);

	g_ul_push_button_trigger = true;
	
	static signed portBASE_TYPE xHigherPriorityTaskWoken;
	
	xHigherPriorityTaskWoken = pdFALSE;
	xSemaphoreGiveFromISR( xDisplaySemaphore, pdTRUE );

	portYIELD_FROM_ISR( xHigherPriorityTaskWoken );
	
	
}

/**
 * \brief Intialize Vsync_Handler.
 */
static void init_vsync_interrupts(void)
{
	/* Initialize PIO interrupt handler, see PIO definition in conf_board.h
	**/
	pio_handler_set(OV7740_VSYNC_PIO, OV7740_VSYNC_ID, OV7740_VSYNC_MASK,
			OV7740_VSYNC_TYPE, vsync_handler);

	/*Set priority of vsync interrupt*/
	NVIC_SetPriority((IRQn_Type)OV7740_VSYNC_ID, 15);

	/* Enable PIO controller IRQs */
	NVIC_EnableIRQ((IRQn_Type)OV7740_VSYNC_ID);
}

/**
 * \brief Configure push button and initialize button_handler interrupt.
 */
static void configure_button(void)
{
	/* Configure PIO clock. */
	pmc_enable_periph_clk(PUSH_BUTTON_ID);

	/* Adjust PIO debounce filter using a 10 Hz filter. */
	pio_set_debounce_filter(PUSH_BUTTON_PIO, PUSH_BUTTON_PIN_MSK, 10);

	/* Initialize PIO interrupt handler, see PIO definition in conf_board.h
	**/
	pio_handler_set(PUSH_BUTTON_PIO, PUSH_BUTTON_ID, PUSH_BUTTON_PIN_MSK,
			PUSH_BUTTON_ATTR, button_handler);

	/*Set priority of push button interrupt*/
	NVIC_SetPriority((IRQn_Type)PUSH_BUTTON_ID, 15);

	/* Enable PIO controller IRQs. */
	NVIC_EnableIRQ((IRQn_Type)PUSH_BUTTON_ID);
	
	/* Enable PIO interrupt lines. */
	pio_enable_interrupt(PUSH_BUTTON_PIO, PUSH_BUTTON_PIN_MSK);
}

/**
 * \brief Initialize PIO capture for the OV7740 image sensor communication.
 *
 * \param p_pio PIO instance to be configured in PIO capture mode.
 * \param ul_id Corresponding PIO ID.
 */
static void pio_capture_init(Pio *p_pio, uint32_t ul_id)
{
	/* Enable periphral clock */
	pmc_enable_periph_clk(ul_id);

	/* Disable pio capture */
	p_pio->PIO_PCMR &= ~((uint32_t)PIO_PCMR_PCEN);

	/* Disable rxbuff interrupt */
	p_pio->PIO_PCIDR |= PIO_PCIDR_RXBUFF;

	/* 32bit width*/
	p_pio->PIO_PCMR &= ~((uint32_t)PIO_PCMR_DSIZE_Msk);
	p_pio->PIO_PCMR |= PIO_PCMR_DSIZE_WORD;

	/* Only HSYNC and VSYNC enabled */
	p_pio->PIO_PCMR &= ~((uint32_t)PIO_PCMR_ALWYS);
	p_pio->PIO_PCMR &= ~((uint32_t)PIO_PCMR_HALFS);

#if !defined(DEFAULT_MODE_COLORED)
	/* Samples only data with even index */
	p_pio->PIO_PCMR |= PIO_PCMR_HALFS;
	p_pio->PIO_PCMR &= ~((uint32_t)PIO_PCMR_FRSTS);
#endif
}

/**
 * \brief Capture OV7740 data to a buffer.
 *
 * \param p_pio PIO instance which will capture data from OV7740 iamge sensor.
 * \param p_uc_buf Buffer address where captured data must be stored.
 * \param ul_size Data frame size.
 */
static uint8_t pio_capture_to_buffer(Pio *p_pio, uint8_t *uc_buf,
		uint32_t ul_size)
{
	/* Check if the first PDC bank is free */
	if ((p_pio->PIO_RCR == 0) && (p_pio->PIO_RNCR == 0)) {
		p_pio->PIO_RPR = (uint32_t)uc_buf;
		p_pio->PIO_RCR = ul_size;
		p_pio->PIO_PTCR = PIO_PTCR_RXTEN;
		return 1;
	} else if (p_pio->PIO_RNCR == 0) {
		p_pio->PIO_RNPR = (uint32_t)uc_buf;
		p_pio->PIO_RNCR = ul_size;
		return 1;
	} else {
		return 0;
	}
}

/**
 * \brief Intialize LCD display.
 */
static void display_init(void)
{
	struct ili9325_opt_t ili9325_display_opt;

	/* Enable peripheral clock */
	pmc_enable_periph_clk( ID_SMC );

	/* Configure SMC interface for LCD */
	smc_set_setup_timing(SMC, ILI9325_LCD_CS, SMC_SETUP_NWE_SETUP(2)
			| SMC_SETUP_NCS_WR_SETUP(2)
			| SMC_SETUP_NRD_SETUP(2)
			| SMC_SETUP_NCS_RD_SETUP(2));

	smc_set_pulse_timing(SMC, ILI9325_LCD_CS, SMC_PULSE_NWE_PULSE(4)
			| SMC_PULSE_NCS_WR_PULSE(4)
			| SMC_PULSE_NRD_PULSE(10)
			| SMC_PULSE_NCS_RD_PULSE(10));

	smc_set_cycle_timing(SMC, ILI9325_LCD_CS, SMC_CYCLE_NWE_CYCLE(10)
			| SMC_CYCLE_NRD_CYCLE(22));

	smc_set_mode(SMC, ILI9325_LCD_CS, SMC_MODE_READ_MODE
			| SMC_MODE_WRITE_MODE);

	/* Initialize display parameter */
	ili9325_display_opt.ul_width = ILI9325_LCD_WIDTH;
	ili9325_display_opt.ul_height = ILI9325_LCD_HEIGHT;
	ili9325_display_opt.foreground_color = COLOR_BLACK;
	ili9325_display_opt.background_color = COLOR_WHITE;

	/* Switch off backlight */
	aat31xx_disable_backlight();

	/* Initialize LCD */
	ili9325_init(&ili9325_display_opt);

	/* Set backlight level */
	aat31xx_set_backlight(AAT31XX_MAX_BACKLIGHT_LEVEL);

	/* Turn on LCD */
	ili9325_display_on();
}

/**
 * \brief Initialize PIO capture and the OV7740 image sensor.
 */
static void capture_init(void)
{
	twi_options_t opt;

	/* Init Vsync handler*/
	init_vsync_interrupts();

	/* Init PIO capture*/
	pio_capture_init(OV_DATA_BUS_PIO, OV_DATA_BUS_ID);

	/* Turn on ov7740 image sensor using power pin */
	ov_power(true, OV_POWER_PIO, OV_POWER_MASK);

	/* Init PCK0 to work at 24 Mhz */
	/* 96/4=24 Mhz */
	PMC->PMC_PCK[0] = (PMC_PCK_PRES_CLK_4 | PMC_PCK_CSS_PLLA_CLK);
	PMC->PMC_SCER = PMC_SCER_PCK0;
	while (!(PMC->PMC_SCSR & PMC_SCSR_PCK0)) {
	}

	/* Enable TWI peripheral */
	pmc_enable_periph_clk(ID_BOARD_TWI);

	/* Init TWI peripheral */
	opt.master_clk = sysclk_get_cpu_hz();
	opt.speed      = TWI_CLK;
	twi_master_init(BOARD_TWI, &opt);

	/* Configure TWI interrupts */
	NVIC_DisableIRQ(BOARD_TWI_IRQn);
	NVIC_ClearPendingIRQ(BOARD_TWI_IRQn);
	NVIC_SetPriority(BOARD_TWI_IRQn, 0);
	NVIC_EnableIRQ(BOARD_TWI_IRQn);

	/* ov7740 Initialization */
	while (ov_init(BOARD_TWI) == 1) {
	}

	/* ov7740 configuration */
	ov_configure(BOARD_TWI, QVGA_YUV422_20FPS);

	/* Wait 3 seconds to let the image sensor to adapt to environment */
	delay_ms(3000);
}

/**
 * \brief Start picture capture.
 */
static void start_capture(void)
{
	/* Set capturing destination address*/
	g_p_uc_cap_dest_buf = (uint8_t *)CAP_DEST;

	/* Set cap_rows value*/
	g_us_cap_rows = IMAGE_HEIGHT;

	/* Enable vsync interrupt*/
	pio_enable_interrupt(OV7740_VSYNC_PIO, OV7740_VSYNC_MASK);

	/* Capture acquisition will start on rising edge of Vsync signal.
	 * So wait g_vsync_flag = 1 before start process
	 */
	while (!g_ul_vsync_flag) {
	}

	/* Disable vsync interrupt*/
	pio_disable_interrupt(OV7740_VSYNC_PIO, OV7740_VSYNC_MASK);

	/* Enable pio capture*/
	pio_capture_enable(OV7740_DATA_BUS_PIO);

	/* Capture data and send it to external SRAM memory thanks to PDC
	 * feature */
	pio_capture_to_buffer(OV7740_DATA_BUS_PIO, g_p_uc_cap_dest_buf,
			(g_us_cap_line * g_us_cap_rows) >> 2);

	/* Wait end of capture*/
	while (!((OV7740_DATA_BUS_PIO->PIO_PCISR & PIO_PCIMR_RXBUFF) ==
			PIO_PCIMR_RXBUFF)) {
	}

	/* Disable pio capture*/
	pio_capture_disable(OV7740_DATA_BUS_PIO);

	/* Reset vsync flag*/
	g_ul_vsync_flag = false;
}

void task_zbar(void){
	
	uint8_t ulcursor;
	
	zbar_image_scanner_t *scanner = NULL;
	/* create a reader */
	scanner = zbar_image_scanner_create();
	/* configure the reader */
	zbar_image_scanner_set_config(scanner, 0, ZBAR_CFG_ENABLE, 1);
	
	uint8_t * temp = (uint8_t *)CAP_DEST;
	
	/* wrap image data */
	zbar_image_t *image = zbar_image_create();
	zbar_image_set_format(image, zbar_fourcc('G','R','E','Y'));
	zbar_image_set_size(image, IMAGE_WIDTH, IMAGE_HEIGHT);
	zbar_image_set_data(image, temp, IMAGE_WIDTH * IMAGE_HEIGHT, zbar_image_free_data);

	/*manual raw data string test*/
	//zbar_image_t *image = zbar_image_create();
	//zbar_image_set_format(image, zbar_fourcc('Y','8','0','0'));
	//zbar_image_set_size(image, 6, 190);
	//zbar_image_set_data(image, temp, 6 * 190, zbar_image_free_data);

	/* scan the image for barcodes */
	int n = zbar_scan_image(scanner, image);

	/* extract results */
	const zbar_symbol_t *symbol = zbar_image_first_symbol(image);
	for(; symbol; symbol = zbar_symbol_next(symbol)) {
		/* print the results */
		zbar_symbol_type_t typ = zbar_symbol_get_type(symbol);
		volatile const char *data = zbar_symbol_get_data(symbol);
		
		//printf("decoded %s symbol \"%s\"\n", zbar_get_symbol_name(typ), data);
		
		//ili9325_fill(COLOR_YELLOW);
		//ili9325_draw_string(0, 20, (uint8_t *)"FOUND IMAGE");
		//ili9325_draw_string(0, 20, (uint8_t *)zbar_get_symbol_name(typ));
		//ili9325_draw_string(0, 80, (uint8_t *)data);

		ili9325_draw_prepare(0, 0, IMAGE_HEIGHT, IMAGE_WIDTH);
		ili9325_fill(COLOR_YELLOW);
		ili9325_draw_string(0, 20, (uint8_t *)"found image");
		ili9325_draw_string(0, 80, (uint8_t *)"UPC code");


		
	}

	/* clean up */
	//zbar_image_destroy(image);
	//zbar_image_scanner_destroy(scanner);	
	
	
}



/**
 * \brief Configure SMC interface for SRAM.
 */
static void board_configure_sram( void )
{
	/* Enable peripheral clock */
	pmc_enable_periph_clk( ID_SMC );

	/* Configure SMC interface for SRAM */
	smc_set_setup_timing(SMC, SRAM_CS, SMC_SETUP_NWE_SETUP(2)
			| SMC_SETUP_NCS_WR_SETUP(0)
			| SMC_SETUP_NRD_SETUP(3)
			| SMC_SETUP_NCS_RD_SETUP(0));

	smc_set_pulse_timing(SMC, SRAM_CS, SMC_PULSE_NWE_PULSE(4)
			| SMC_PULSE_NCS_WR_PULSE(5)
			| SMC_PULSE_NRD_PULSE(4)
			| SMC_PULSE_NCS_RD_PULSE(6));

	smc_set_cycle_timing(SMC, SRAM_CS, SMC_CYCLE_NWE_CYCLE(6)
			| SMC_CYCLE_NRD_CYCLE(7));

	smc_set_mode(SMC, SRAM_CS, SMC_MODE_READ_MODE
			| SMC_MODE_WRITE_MODE);
}

#ifdef DEFAULT_MODE_COLORED

/**
 * \brief Take a 32 bit variable in parameters and returns a value between 0 and
 * 255.
 *
 * \param i Enter value .
 * \return i if 0<i<255, 0 if i<0 and 255 if i>255
 */
static inline uint8_t clip32_to_8( int32_t i )
{
	if (i > 255) {
		return 255;
	}

	if (i < 0) {
		return 0;
	}

	return (uint8_t)i;
}

/**
 * \brief Draw LCD in color with integral algorithm.
 */
static void draw_frame_yuv_color_int( void )
{
	uint32_t ul_cursor;
	int32_t l_y1;
	int32_t l_y2;
	int32_t l_v;
	int32_t l_u;
	int32_t l_blue;
	int32_t l_green;
	int32_t l_red;
	uint8_t *p_uc_data;
	
	volatile uint8_t *p_y_data;
	volatile uint32_t tempcursor;
	
	p_uc_data = (uint8_t *)g_p_uc_cap_dest_buf;
	p_y_data = (uint8_t *)g_p_uc_cap_dest_buf;
	
	/* Configure LCD to draw captured picture */
	LCD_IR(0);
	LCD_IR(ILI9325_ENTRY_MODE);
	LCD_WD(((ILI9325_ENTRY_MODE_BGR | ILI9325_ENTRY_MODE_AM |
			ILI9325_ENTRY_MODE_DFM | ILI9325_ENTRY_MODE_TRI |
			ILI9325_ENTRY_MODE_ORG) >> 8) & 0xFF);
	LCD_WD((ILI9325_ENTRY_MODE_BGR | ILI9325_ENTRY_MODE_AM |
			ILI9325_ENTRY_MODE_DFM | ILI9325_ENTRY_MODE_TRI |
			ILI9325_ENTRY_MODE_ORG) & 0xFF);
	ili9325_draw_prepare(0, 0, IMAGE_HEIGHT, IMAGE_WIDTH);

	/* OV7740 Color format is YUV422. In this format pixel has 4 bytes
	 * length (Y1,U,Y2,V).
	 * To display it on LCD,these pixel need to be converted in RGB format.
	 * The output of this conversion is two 3 bytes pixels in (B,G,R)
	 * format. First one is calculed using Y1,U,V and the other one with
	 * Y2,U,V. For that reason cap_line is twice bigger in color mode
	 * than in black and white mode. */
	for (ul_cursor = IMAGE_WIDTH * IMAGE_HEIGHT; ul_cursor != 0;
			ul_cursor -= 2, p_uc_data += 4, p_y_data += 2) {
		l_y1 = p_uc_data[0]; /* Y1 */
		l_y1 -= 16;
		l_v = p_uc_data[3]; /* V */
		l_v -= 128;
		l_u = p_uc_data[1]; /* U */
		l_u -= 128;

		l_blue = 516 * l_v + 128;
		l_green = -100 * l_v - 208 * l_u + 128;
		l_red = 409 * l_u + 128;

		/* BLUE */
		LCD_WD( clip32_to_8((298 * l_y1 + l_blue) >> 8));
		/* GREEN */
		LCD_WD( clip32_to_8((298 * l_y1 + l_green) >> 8));
		/* RED */
		LCD_WD( clip32_to_8((298 * l_y1 + l_red) >> 8));

		l_y2 = p_uc_data[2]; /* Y2 */
		l_y2 -= 16;
		LCD_WD( clip32_to_8((298 * l_y2 + l_blue) >> 8));
		LCD_WD( clip32_to_8((298 * l_y2 + l_green) >> 8));
		LCD_WD( clip32_to_8((298 * l_y2 + l_red) >> 8));				
		
		p_y_data[0] = p_uc_data[0];		//	Y1
		p_y_data[1] = p_uc_data[2];		//	Y2
		
		tempcursor = ul_cursor;
	}
	task_zbar();
}

#else

/**
 * \brief Draw LCD in black and white with integral algorithm.
 */
static void draw_frame_yuv_bw8( void )
{
	volatile uint32_t ul_cursor;
	uint8_t *p_uc_data;
	uint8_t *p_rgb_data;
	
	p_uc_data = (uint8_t *)g_p_uc_cap_dest_buf;
	p_rgb_data = (uint8_t *)g_p_uc_cap_dest_buf;

	/* Configure LCD to draw captured picture */
	LCD_IR(0);
	LCD_IR(ILI9325_ENTRY_MODE);
	LCD_WD(((ILI9325_ENTRY_MODE_BGR | ILI9325_ENTRY_MODE_AM |
			ILI9325_ENTRY_MODE_DFM | ILI9325_ENTRY_MODE_TRI |
			ILI9325_ENTRY_MODE_ORG) >> 8) & 0xFF);
	LCD_WD((ILI9325_ENTRY_MODE_BGR | ILI9325_ENTRY_MODE_AM |
			ILI9325_ENTRY_MODE_DFM | ILI9325_ENTRY_MODE_TRI |
			ILI9325_ENTRY_MODE_ORG) & 0xFF);
	ili9325_draw_prepare(0, 0, IMAGE_HEIGHT, IMAGE_WIDTH);

	/* LCD pixel has 24bit data. In black and White mode data has 8bit only
	 * so
	 * this data must be written three time in LCD memory.
	 */
	for (ul_cursor = IMAGE_WIDTH * IMAGE_HEIGHT; ul_cursor != 0;
			ul_cursor--, p_uc_data++, p_rgb_data++) {
		/* Black and White using Y */
		LCD_WD( *p_uc_data );
		LCD_WD( *p_uc_data );
		LCD_WD( *p_uc_data );
		*p_rgb_data = *p_uc_data;		
	}
}

#endif








//~~~~~~~~~~~~~~~ Begin FreeRTOS specific fcns ~~~~~~~~~~~~~~~~~~~~~~

/**
 * \brief Handler for Sytem Tick interrupt.
 */
//void SysTick_Handler(void)
//{
//	xPortSysTickHandler();
//}

void vApplicationMallocFailedHook( void )
{
	/* vApplicationMallocFailedHook() will only be called if
	configUSE_MALLOC_FAILED_HOOK is set to 1 in FreeRTOSConfig.h.  It is a hook
	function that will get called if a call to pvPortMalloc() fails.
	pvPortMalloc() is called internally by the kernel whenever a task, queue,
	timer or semaphore is created.  It is also called by various parts of the
	demo application.  If heap_1.c or heap_2.c are used, then the size of the
	heap available to pvPortMalloc() is defined by configTOTAL_HEAP_SIZE in
	FreeRTOSConfig.h, and the xPortGetFreeHeapSize() API function can be used
	to query the size of free heap space that remains (although it does not
	provide information on how the remaining heap might be fragmented). */
//	taskDISABLE_INTERRUPTS();
	for( ;; );
}


/**
 * \brief Called if stack overflow during execution
 */
extern void vApplicationStackOverflowHook(xTaskHandle *pxTask,
		signed char *pcTaskName)
{
	//printf("stack overflow %x %s\r\n", pxTask, (portCHAR *)pcTaskName);
	/* If the parameters have been corrupted then inspect pxCurrentTCB to
	 * identify which task has overflowed its stack.
	 */
	LED_On(LED0_GPIO);
	for (;;) {
	}
}

/**
 * \brief This function is called by FreeRTOS idle task
 */
extern void vApplicationIdleHook(void)
{
}

/**
 * \brief This function is called by FreeRTOS each tick
 */
extern void vApplicationTickHook(void)
{
}

//~~~~~~~~~~~~~~~ End FreeRTOS specific fcns ~~~~~~~~~~~~~~~~~~~~~~


//~~~~~~~~~~~~~~~ Begin FreeRTOS task ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
/**
 * \brief This task, when activated, make LED blink at a fixed rate
 */


static void task_led(void *pvParameters)
{
	UNUSED(pvParameters);
	for (;;) {
		LED_Toggle(LED0_GPIO);
		vTaskDelay(500);
	}
}

static void task_lcdscreen(void *pvParameters)
{
	UNUSED(pvParameters);
	for (;;) {
		ili9325_fill(COLOR_VIOLET);
		ili9325_draw_string(0, 20, (uint8_t *)"FreeRTOS");
		ili9325_draw_string(0, 80, (uint8_t *)"DEMO");
		vTaskDelay(5000);
	}
}

static void task_display(void *pvParameters)
{
	UNUSED(pvParameters);
	//vSemaphoreCreateBinary(xDisplaySemaphore);
	xDisplaySemaphore = xSemaphoreCreateBinary();

	for (;;){
		
		if (xDisplaySemaphore != NULL){
			
			if (xSemaphoreTake(xDisplaySemaphore, portMAX_DELAY ) == pdTRUE){		
				ili9325_fill(COLOR_BLUE);
				ili9325_draw_string(0, 20, (uint8_t *)"task_display");
				ili9325_draw_string(0, 80, (uint8_t *)"initializing camera");		
			
				//init capture dest addr + height
				/* Enable vsync interrupt*/
				pio_enable_interrupt(OV7740_VSYNC_PIO, OV7740_VSYNC_MASK);

			}
			
		}
		
		vTaskDelay(10 / portTICK_RATE_MS);
	}
}

static void task_camera(void *pvParameters)
{
	UNUSED(pvParameters);
	xCameraSemaphore = xSemaphoreCreateBinary();

	/* Set capturing destination address*/
	//g_p_uc_cap_dest_buf = (uint8_t *)CAP_DEST;

	/* Set cap_rows value*/
	//g_us_cap_rows = IMAGE_HEIGHT;

	for (;;){
		
		if (xCameraSemaphore != NULL){
			
			if (xSemaphoreTake(xCameraSemaphore, portMAX_DELAY ) == pdTRUE){				

				//HACK
				g_p_uc_cap_dest_buf = (uint8_t *)CAP_DEST;
				g_us_cap_rows = IMAGE_HEIGHT;
				
				/* Disable vsync interrupt*/
				pio_disable_interrupt(OV7740_VSYNC_PIO, OV7740_VSYNC_MASK);
				/* Enable pio capture*/
				pio_capture_enable(OV7740_DATA_BUS_PIO);
				/* Capture data and send it to external SRAM memory thanks to PDC feature */
				pio_capture_to_buffer(OV7740_DATA_BUS_PIO, g_p_uc_cap_dest_buf, (g_us_cap_line * g_us_cap_rows) >> 2);

				/* Wait end of capture*/
				while (!((OV7740_DATA_BUS_PIO->PIO_PCISR & PIO_PCIMR_RXBUFF) == PIO_PCIMR_RXBUFF)) {
					
				}

				/* Disable pio capture*/
				pio_capture_disable(OV7740_DATA_BUS_PIO);				
								
				/* LCD display information*/
				ili9325_fill(COLOR_RED);
				ili9325_draw_string(0, 20, (uint8_t *)"Picture saved");
				
				_display();
			
			}
			
		}
		
		vTaskDelay(10 / portTICK_RATE_MS);
	}

}


//~~~~~~~~~~~~~~~ End FreeRTOS task ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


/**
 * \brief Application entry point for image sensor capture example.
 *
 * \return Unused (ANSI-C compatibility).
 */
int main(void)
{
	sysclk_init();
	NVIC_SetPriorityGrouping( 0 );
	board_init();

	/* OV7740 send image sensor data at 24 Mhz. For best performances, PCK0
	 * which will capture OV7740 data, has to work at 24Mhz. It's easier and
	 * optimum to use one PLL for core (PLLB) and one other for PCK0 (PLLA).
	 */
	pmc_enable_pllack(7, 0x1, 1); /* PLLA work at 96 Mhz */

	/* LCD display initialization */
	display_init();

	/* LCD display information */
	ili9325_fill(COLOR_TURQUOISE);
	ili9325_draw_string(0, 20,
			(uint8_t *)"OV7740 image sensor\ncapture example");
	ili9325_draw_string(0, 80,
			(uint8_t *)"Please Wait during \ninitialization");

	/* Configure SMC interface for external SRAM. This SRAM will be used
	 * to store picture during image sensor acquisition.
	 */
	board_configure_sram();

	/* Configure push button to generate interrupt when the user press it */
	configure_button();

	/* OV7740 image sensor initialization*/
	capture_init();

	/* LCD display information*/
	ili9325_fill(COLOR_TURQUOISE);
	ili9325_draw_string(0, 20,
			(uint8_t *)"OV7740 image sensor\ncapture example");
	ili9325_draw_string(0, 80,
			(uint8_t *)"Please Press button\nto take and display\na picture");

	LED_On(LED0_GPIO);
	delay_ms(2000);
	LED_Off(LED0_GPIO);
	delay_ms(1000);
	LED_On(LED0_GPIO);

	/*while (1) {
		while (!g_ul_push_button_trigger) { 
		}
		g_ul_push_button_trigger = false;

		start_capture();

		_display();
	}*/

//~~~~~~~ FreeRTOS specific init ~~~~~~~~~~~~~~~~~~~

	/* Create task to make led blink */
	if (xTaskCreate(task_led, "Led", TASK_LED_STACK_SIZE, NULL,
	TASK_LED_STACK_PRIORITY, NULL) != pdPASS) {
		//printf("Failed to create test led task\r\n");
	}

	/* Create task to make led blink */
	if (xTaskCreate(task_lcdscreen, "LCD", TASK_LED_STACK_SIZE, NULL,
	TASK_LED_STACK_PRIORITY, NULL) != pdPASS) {
		//printf("Failed to create test led task\r\n");
	}

	/* Create task to make led blink */
	if (xTaskCreate(task_display, "Display", TASK_LED_STACK_SIZE, NULL,
	TASK_LED_STACK_PRIORITY, NULL) != pdPASS) {
		//printf("Failed to create test led task\r\n");
	}
	
	/* Create task to make led blink */
	if (xTaskCreate(task_camera, "Camera", TASK_LED_STACK_SIZE, NULL,
	TASK_LED_STACK_PRIORITY, NULL) != pdPASS) {
		//printf("Failed to create test led task\r\n");
	}	

	vTaskStartScheduler();
	
//~~~~~~~ end FreeRTOS specific init ~~~~~~~~~~~~~~~~~~~	
	
	/* Will only get here if there was insufficient memory to create the idle task. */
	return 0;	
	
	
}
