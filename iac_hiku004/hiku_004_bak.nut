// Copyright 2013 Katmandu Technology, Inc. All rights reserved. Confidential.
// Setup the server to behave when we have the no-wifi condition
imp.setpoweren(true);
server.setsendtimeoutpolicy(RETURN_ON_ERROR, WAIT_TIL_SENT, 30);

// Always enable blinkup to keep LED flashing; power costs are negligibles
imp.enableblinkup(true);

local entryTime = hardware.millis();

const SCAN_DEBUG_SAMPLES = 1024;
const IMAGE_COLUMNS = 1016;
const FLASH_BLOCK = 1024;
SCAN_MAX_BYTES <- SCAN_DEBUG_SAMPLES*IMAGE_COLUMNS;
const UART_BUF_SIZE = 1024;

// GLOBALS AND CONSTS ----------------------------------------------------------

const BLOCKSIZE = 4096; // bytes per buffer of data sent from agent
const STM32_SECTORSIZE = 0x4000;
const BAUD = 115200; // any standard baud between 9600 and 115200 is allowed
                    
BYTE_TIME <- 8.0 / (BAUD * 1.0);

const PS_OUT_OF_SYNC = 0;
const PS_TYPE_FIELD = 4;
const PS_LEN_FIELD = 5;
const PS_DATA_FIELD = 6;
const PS_PREAMBLE = "\xDE\xAD\xBE\xEF";
const PKT_TYPE_AUDIO = 0x10;
const PKT_TYPE_SCAN = 0x20;
const AUDIO_PAYLOAD_LEN = 192;

audio_pkt_blob <- blob(AUDIO_PAYLOAD_LEN);

packet_state <- {
				 state=PS_OUT_OF_SYNC,
				 char_string = "",
				 type=0,
				 pay_len=0
                }

/*
gInitTime <- { 
        	overall = 0, 
				piezo = 0, 
				button = 0, 
				accel = 0,
				scanner = 0,
				charger = 0,
				inthandler = 0,
				init_stage1 = 0,
				init_stage2 = 0,
				init_unused = 0,
			}; 
*/
local connection_available = false;

is_hiku004 <- true;

if (is_hiku004) {
    CPU_INT             <- hardware.pinW;
    EIMP_AUDIO_IN       <- hardware.pinN; // "EIMP-AUDIO_IN" in schematics
    EIMP_AUDIO_OUT      <- hardware.pinC; // "EIMP-AUDIO_OUT" in schematics
    //RXD_IN_FROM_SCANNER <- hardware.pin7;
    I2C_IF              <- hardware.i2cFG;
    SCL_OUT             <- hardware.pinF;
    SDA_OUT             <- hardware.pinG;
    BATT_VOLT_MEASURE   <- hardware.pinH;
    //CHARGE_DISABLE_H    <- hardware.pinC;
    //SCANNER_UART        <- hardware.uart57;
    BTN_N               <- hardware.pinX;
    ACCEL_INT           <- hardware.pinQ;
    CHARGER_INT_N       <- hardware.pinA;
    AUDIO_UART          <- hardware.uartUVGD;
    IMP_ST_CLK          <- hardware.pinM;
    nrst                <- hardware.pinS;
    boot0               <- hardware.pinJ;
} else {
    CPU_INT             <- hardware.pin1;
    EIMP_AUDIO_IN       <- hardware.pin2; // "EIMP-AUDIO_IN" in schematics
    EIMP_AUDIO_OUT      <- hardware.pin5; // "EIMP-AUDIO_OUT" in schematics
    RXD_IN_FROM_SCANNER <- hardware.pin7;
    I2C_IF              <- hardware.i2c89;
    SCL_OUT             <- hardware.pin8;
    SDA_OUT             <- hardware.pin9;
    BATT_VOLT_MEASURE   <- hardware.pinB;
    //CHARGE_DISABLE_H    <- hardware.pinC;
    SCANNER_UART        <- hardware.uart57;
}


/*
// BOOT UP REASON MASK
const BOOT_UP_REASON_COLD_BOOT= 0x0000h;
const BOOT_UP_REASON_ACCEL    =    1 << 0; // 0x0001h
const BOOT_UP_REASON_CHRG_ST  =    1 << 1; // 0x0002h
const BOOT_UP_REASON_BTUTTON  =    1 << 2; // 0x0004h
const BOOT_UP_REASON_TOUCH	  =    1 << 3; // 0x0008h
const BOOT_UP_REASON_SW_VCC   =    1 << 4; // 0x0010h
const BOOT_UP_REASON_SCAN_TRIG=    1 << 5; // 0x0020h
const BOOT_UP_REASON_SCAN_RST =    1 << 6; // 0x0040h
const BOOT_UP_REASON_CHRG_DET =    1 << 7; // 0x0080h
*/

// This NV persistence is only good for warm boot
// if we get a cold boot, all of this goes away
// If a cold persistence is required then we need to
// user the server.setpermanent() api
if (!("nv" in getroottable()))
{
    nv <- { 
        	sleep_count = 0, 
    	    setup_required=true, 
    	    setup_count = 0,
    	    disconnect_reason=0, 
    	    sleep_not_allowed=false,
    	    boot_up_reason = 0,
    	    voltage_level = 0.0,
    	    sleep_duration = 0.0,
    	  };
}

if(!("setup" in getroottable()))
{
    setup <- {
                 ssid="",
				 pass="",
				 barcode_scanned=false,
				 time=0.0,
             }
}

// Get the Sleep Duration early on
if( nv.sleep_count != 0 )
{
	nv.sleep_duration = time() - nv.sleep_duration;
}

// Consts and enums
const cFirmwareVersion = "1.3.02" // Beta3 firmware starts with 1.3.00
const cButtonTimeout = 6;  // in seconds
//const cDelayBeforeDeepSleepHome = 30.0;  // in seconds and just change this one
const cDelayBeforeDeepSleepHome = 10000.0;  // in seconds and just change this one
const cDelayBeforeDeepSleepFactory = 300.0;  // in seconds and just change this one
// The two variables below here are to use a hysteresis for the Accelerometer to stop
// moving, and if the accelerometer doesn�t stop moving within the cDelayBeforeAccelClear
// then we don�t go to sleep. Here is how it would work:
// 1. cActualDelayBeforeDeepSleep timer is kicked off
// 2. enters the sleep Handler when the timer expires
// 3. we set a timer for cDelayBeforeAccelClear and check for Acceleremoter
//    interrupts and if we are still receiving interrupts even after the timer expires
//    we simply don�t enter sleep
// 4. Otherwise if there are no more interrupts generated by the Accelerometer then
//    We enter sleep
local cActualDelayBeforeDeepSleep = cDelayBeforeDeepSleepHome - 2;
const cDeepSleepDuration = 86380.0;  // in seconds (24h - 20s)
const cDeepSleepInSetupMode = 2419180.0; // 28 days - 20seconds
const BLINK_UP_TIME = 600.0; // in seconds (10 minutes)

// This is the number of button presses required to enter blink up mode
const BLINK_UP_BUTTON_COUNT = 3;

const CONNECT_RETRY_TIME = 45; // for now 45 seconds retry time

const SETUP_BARCODE_PREFIX = "4H1KU5"

// use the factory BSSID to ensure scanning the special barcodes
// on the hiku box only works in the factory
// HACK
const FACTORY_BSSID = "20aa4b532731";

enum DeviceState
/*
                           ---> SCAN_CAPTURED ------>
                          /                          \
    IDLE ---> SCAN_RECORD ---> BUTTON_TIMEOUT -->     \
                          \                      \     \
                           -------------------> BUTTON_RELEASED ---> IDLE
*/
{
    IDLE,             // 0: Not recording or processing data
    SCAN_RECORD,      // 1: Scanning and recording audio
    SCAN_CAPTURED,    // 2: Processing scan data
    BUTTON_TIMEOUT,   // 3: Timeout limit reached while holding button
    BUTTON_RELEASED,  // 4: Button released, may have audio to send
    PRE_SLEEP,        // 5: A state before it enters Sleep just after being IDLE
}


// Globals
gDeviceState <- null; // Hiku device current state
local init_completed = false;

gAudioBufferOverran <- false; // True if an overrun occurred
gAudioChunkCount <- 0; // Number of audio buffers (chunks) captured
const gAudioBufferSize = 2000; // Size of each audio buffer 
const gAudioSampleRate = 8000; // in Hz
local sendBufferSize = 24*1024; // 16K send buffer size

// Workaround to capture last buffer after sampler is stopped
gSamplerStopping <- false; 
gLastSamplerBuffer <- null; 
gLastSamplerBufLen <- 0; 
gAudioTimer <- 0;

gAccelInterrupted <- false;
gIsConnecting <- false;
gDeepSleepTimer <- null;

// Each 1k of buffer will hold 1/16 of a second of audio, or 63ms.
// A-law sampler does not return partial buffers. This means that up to 
// the last buffer size of data is dropped. Filed issue with IE here: 
// http://forums.electricimp.com/discussion/780/. So keep buffers small. 
buf1 <- blob(gAudioBufferSize);
buf2 <- blob(gAudioBufferSize);
buf3 <- blob(gAudioBufferSize);
buf4 <- blob(gAudioBufferSize);


lines_scanned <- 0;
scan_byte_cnt <- 0;
scanner_error <- false;

// Device Setup Related functions
function determineSetupBarcode(barcode)
{
   // local patternString = format("\b%s\b",SETUP_BARCODE_PREFIX);
    local pattern = regexp(@"\b4H1KU");
    local res = pattern.search(barcode);
	local tempBarcode = barcode;
	server.log(format("Barcode to Match: %s",barcode));
	server.log("result: "+res);
	// result is null which means its not the setup barcode
	if( res == null)
	{
	   server.log("regex didn't fint a setup barcode");
	   return false;
	}
	
	// At this time we have a barcode that has either an ssid or a password
	// decode it by stripping the first character which identifies an ssid if its 5
	// identifies a password if its a 6
	
	local barcodeType = tempBarcode.slice(res.end, res.end+1);
	local setupCode = tempBarcode.slice(res.end+1, tempBarcode.len());
	
	if(barcodeType == "5")
	{
        // This is the SSID
		setup.ssid = setupCode;
	}
	else if( barcodeType == "6")
	{
        // This is the password
		setup.pass = setupCode;
	}
	
	
	server.log(" setupCode: "+setupCode+" type: "+barcodeType);
	
	if(setup.ssid !="" && setup.pass !="")
	{
       imp.wakeup(0.1 function(){
	        ChangeWifi(setup.ssid, setup.pass);
            setup.ssid = setup.pass = "";
	   });
	}
	
	return true;
}

function ChangeWifi(ssid, password) {
    server.log("device disconnecting");
    // wait for wifi buffer to empty before disconnecting
    server.flush(60);
    server.disconnect();
    
    // change the wificonfiguration and then reconnect
    imp.setwificonfiguration(ssid, password);
    server.connect();
    
    // log that we're connected to make sure it worked
    server.log("device reconnected to " + ssid);
}


//======================================================================
// Class to handle all the connection management and retry mechanisms
// This will self contain all the wifi connection establishment and retries

class ConnectionManager
{
	_connCb = array(2);
	numCb = 0;
	
	constructor()
	{
	}
	
	function registerCallback(func)
	{
		if( numCb > _connCb.len() )
		{
			_connCb.resize(numCb+2);
		}
		
		_connCb[numCb++] = func;
	}
	
	function init_connections()
	{
 		if( server.isconnected() )
		{
			notifyConnectionStatus(SERVER_CONNECTED);
		}
		else
		{
			server.connect(onConnectedResume.bindenv(this), CONNECT_RETRY_TIME);
		}

    	//hwPiezo.playSound("no-connection");
    	server.onunexpecteddisconnect(onUnexpectedDisconnect.bindenv(this));
		server.onshutdown(onShutdown.bindenv(this));    	
    	
	}
	
	function notifyConnectionStatus(status)
	{
		local i = 0;
		for( i = 0; i < numCb; i++ )
		{
			_connCb[i](status);
		}
	}
	

	//********************************************************************
	// This is to make sure that we wake up and start trying to connect on the background
	// only time we would get into onConnected is when we have a connection established
	// otherwise its going to beep left and right which is nasty!
	function onConnectedResume(status)
	{
		if( status != SERVER_CONNECTED && !nv.setup_required )
		{
			nv.disconnect_reason = status;
			imp.wakeup(2, tryToConnect.bindenv(this) );
			//hwPiezo.playSound("no-connection");
			connection_available = false;
		}
		else
		{
			connection_available = true;
			notifyConnectionStatus(status);
		}
	}

	function tryToConnect()
	{
    	if (!server.isconnected() && !gIsConnecting && !nv.setup_required ) {
    		gIsConnecting = true;
        	server.connect(onConnectedResume.bindenv(this), CONNECT_RETRY_TIME);
        	imp.wakeup(CONNECT_RETRY_TIME+2, tryToConnect.bindenv(this));
    	}
	}

	function onUnexpectedDisconnect(status)
	{
    	nv.disconnect_reason = status;
    	connection_available = false;
    	notifyConnectionStatus(status);
    	if( !gIsConnecting )
    	{
   			imp.wakeup(0.5, tryToConnect.bindenv(this));
   		}
	}
	

	function onShutdown(status)
	{
		agentSend("shutdownRequestReason", status);
		if((status == SHUTDOWN_NEWSQUIRREL) || (status == SHUTDOWN_NEWFIRMWARE))
		{
			hwPiezo.playSound("software-update");
			imp.wakeup(2, function(){
				server.restart();
			});
		}
		else
		{
			server.restart();
		}
	}		
}


//======================================================================
// Class to handle all the Interrupts and Call Backs
class InterruptHandler
{
    // Having a static interrupt handler object as a singleton will be
    // better to handle all the IOExpander classes interrupts one this one object
    irqCallbacks = array(2); // start with this for now
    i2cDevice = null;
  
    // Want to keep the constructor private or protected so that it can only
    // be initialized by the getInstance
    constructor(numFuncs, i2cDevice)
    {
    	//gInitTime.inthandler = hardware.millis();
        this.irqCallbacks.resize(numFuncs);

	if (!is_hiku004) {
            this.i2cDevice = i2cDevice;
            // Disable "Autoclear NINT on RegData read". This 
            // could cause us to lose accelerometer interrupts
            // if someone reads or writes any pin between when 
            // an interrupt occurs and we handle it. 
            i2cDevice.write(0x10, 0x01); // RegMisc
	    
            // Lower the output buffer drive, to reduce current consumption
            i2cDevice.write(0x02, 0xFF); // RegLowDrive          
	}
	
        CPU_INT.configure(DIGITAL_IN_WAKEUP, handlePin1Int.bindenv(this));
    }
  
      // Set an interrupt handler callback for a particular pin
  	function setIrqCallback(pin, func)
  	{
        if( pin > irqCallbacks.len() )
        {
          // someone tried to add a call back function to a pin that is greater
          // than the size of the array
          return;
        }
        irqCallbacks[pin] = func;
    }
	
	
    function clearHandlers()
    {
        for (local i = 0; i < irqCallbacks.len(); i++) {
            irqCallbacks[i] = null;
        }
    }	

    // Handle all expander callbacks
    function handlePin1Int()
    {
        local regInterruptSource = 0;
        local reg = 0;
        
        local pinState = CPU_INT.read();

        // Get the active interrupt sources
        // Keep reading the interrupt source register and clearing 
        // interrupts until it reads clean.  This catches any interrupts
        // that occur between reading and clearing. 
        
        
        //log(format("handlePin1Int: entry time=%d ms, hardware.pin1=%d", hardware.millis(),pinState));
        if(0 == pinState)
        {
        	//log(format("handlePin1Int: fallEdge time=%d ms, hardware.pin1=%d", hardware.millis(),pinState));
        	return;
        }
        
	if (is_hiku004) {
	    // HACK replace CHARGER_INT_N.read() for charging start/stop with I2C call to LP3918 or monitoring of charging current (IMON)
	    local charger_int_n_val = CHARGER_INT_N.read() ? 0 : 1;
	    regInterruptSource = (charger_int_n_val << 7) | ((BTN_N.read() ? 0 : 1) << 2) | (charger_int_n_val << 1) | (ACCEL_INT.read() & 1);
	} else 
	    while (reg = i2cDevice.read(0x0C)) // RegInterruptSource
		{
	    clearAllIrqs();
	    regInterruptSource =  regInterruptSource | reg;
        }
	

        // If no interrupts, just return. This occurs on every 
        // pin 1 falling edge. 
        if (!regInterruptSource) 
        {
        	//log(format("handlePin1Int: fallEdge time=%d ms, hardware.pin1=%d", hardware.millis(),hardware.pin1.read()));
            return;
        }

        //printRegister(0x0C, "INTERRUPT");

        // Call the interrupt handlers for all active interrupts
        for(local pin=0; pin < 8; pin++){
            if(regInterruptSource & (1 << pin)){
                //log(format("-Calling irq callback for pin %d", pin));
                nv.boot_up_reason = nv.boot_up_reason | (1 << pin);
                if (irqCallbacks[pin]) irqCallbacks[pin]();
            }
        }
       // log("handlePin1Int exit time: " + hardware.millis() + "ms");
    } 
    
    // Clear all interrupts.  Must do this immediately after
    // reading the interrupt register in the handler, otherwise
    // we may get other interrupts in between and miss them. 
    function clearAllIrqs()
    {
        i2cDevice.write(0x0C, 0xFF); // RegInterruptSource
    }
    
    function getI2CDevice()
    {
    	return this.i2cDevice;
    } 
  
}


//======================================================================
// Handles all audio output
class Piezo
{
    // The hardware pin controlling the piezo 
    pin = null;
    
    page_device = false;
	pageToneIdx=0;
		
    // In Squirrel, if you initialize a member array or table, all
    // instances will point to the same one.  So init in the constructor.
    tonesParamsList = {};

    // State for playing tones asynchronously
    currentToneIdx = 0;
    currentTone = null;

    // Audio generation constants
    static noteB4 = 0.002025; // 494 Hz 
    static noteE5 = 0.001517; // 659 Hz
    static noteE6 = 0.000759; // 1318 Hz
    static dc = 0.5; // 50% duty cycle, maximum power for a piezo
    static longTone = 0.2; // duration in seconds
    static shortTone = 0.15; // duration in seconds
        // rmk experimenting with a new extrashort tone
    static extraShortTone = 0.1; // duration in seconds

    //**********************************************************
    constructor(hwPin)
    {
    	//gInitTime.piezo = hardware.millis();
        pin = hwPin;
        
	disable();

        tonesParamsList = {
            // [[period, duty cycle, duration], ...]
            // rmk messing with the tones, these were rajan's originals
            //"success": [[noteE5, 0.15, longTone], [noteE6, 0.85, shortTone]],
            //"success-local": [[noteE5, 0.15, longTone]],
            //"start-local": [[noteE6, 0.15, longTone]],
            //"success-server": [[noteE6, 0.85, shortTone]],
            "success": [[noteE5, 0.15, longTone], [noteE6, 0.85, shortTone]],
            "success-local": [[noteE5, dc, longTone]],
            "start-local": [[noteE5, 0.15, longTone]],
            "success-server": [[noteE6, 0.85, shortTone]],

            // rmk these were from rob_audio_test
            //"success": [[noteE5, dc, longTone], [noteE6, dc, shortTone]],
            //"success-local": [[noteE5, dc, longTone]],
            //"success-server": [[noteE6, dc, shortTone]],

            
            "failure": [[noteB4, 0.85, shortTone]],
            "unknown-upc": [[noteB4, 0.85, shortTone], [noteB4, 0, shortTone], 
            [noteB4, 0.85, shortTone], [noteB4, 0, shortTone], 
            [noteB4, 0.85, shortTone], [noteB4, 0, shortTone]],
            "": [/*silence*/],
            "timeout":  [/*silence*/],
            "startup": [[noteB4, 0.85, longTone], [noteE5, 0.15, shortTone]],
            "charger-removed": [[noteE5, 0.15, shortTone], [noteB4, 0.85, longTone]],
            "charger-attached": [[noteB4, 0.85, longTone], [noteE5, 0.15, shortTone]],
            "device-page": [[noteB4, 0.85, shortTone],[noteB4, 0, longTone]],
            // rmk modified the no-connection to a double beep and reduced time to the new extraShortTone
            "no-connection": [[noteB4, 0.85, extraShortTone], [noteB4, 0, extraShortTone], [noteB4, 0.85, extraShortTone], [noteB4, 0, extraShortTone]],
            "blink-up-enabled": [[noteE5, 0, shortTone], [noteB4, 0.85, longTone]],
            "software-update": [[noteB4, 0.85, shortTone], [noteE5, 0, extraShortTone], [noteE5, 0.85, shortTone], [noteB4, 0, extraShortTone]]
        };

        //gInitTime.piezo = hardware.millis() - gInitTime.piezo;
    }
    
    function disable()
    {
	pin.write(0);
    	pin.configure(DIGITAL_OUT);
	pin.write(0);
    }
    
    // utility futimeoutnction to validate that the tone is present
    // and it is not a silent tone
    function validate_tone( tone )
    {
        // Handle invalid tone values
        if (!(tone in tonesParamsList))
        {
            log(format("Error: unknown tone \"%s\"", tone));
            return false;
        }

        // Handle "silent" tones
        if (tonesParamsList[tone].len() == 0)
        {
            return false;
        } 
        return true;   
    }    
    /*
    function isPaging()
    {
    	return page_device;
    }
    
    function stopPageTone()
    {
    	page_device = false;
    }
    
    function playPageTone()
    {
		if( !validate_tone("device-page"))
		{
			return;
		}
    	
    	page_device = true;
    	
    	// Play the first note
        local params = tonesParamsList["device-page"][0];
        pin.configure(PWM_OUT, params[0], params[1]);
            
    	// Play the next note after the specified delay
        pageToneIdx = 1;
        imp.wakeup(params[2], continuePageTone.bindenv(this));   	
    	
    }
    
    // Continue playing the device page tone until a button is pressed
    function continuePageTone()
    {
        // Turn off the previous note
        pin.write(0);
        
        if( !page_device )
        {
        	return;
        }

        // Play the next note, if any
        if (tonesParamsList["device-page"].len() > pageToneIdx)
        {
            local params = tonesParamsList["device-page"][pageToneIdx];
            pin.configure(PWM_OUT, params[0], params[1]);

            pageToneIdx++;
            imp.wakeup(params[2], continuePageTone.bindenv(this));
        }
        else 
        {
            pageToneIdx = 0;
            if( page_device )
            {
            	playPageTone();
            }
        }
    }
    */

    //**********************************************************
    // Play a tone (a set of notes).  Defaults to asynchronous
    // playback, but also supports synchronous via busy waits
    function playSound(tone = "success", async = true) 
    {

		if( !validate_tone( tone ) )
		{
			return;
		}

        if (async)
        {
            // Play the first note
            local params = tonesParamsList[tone][0];
            pin.configure(PWM_OUT, params[0], params[1]);
            // Play the next note after the specified delay
            currentTone = tone;
            currentToneIdx = 1;
            imp.wakeup(params[2], _continueSound.bindenv(this));
        }
        else 
        {
            // Play synchronously
            foreach (params in tonesParamsList[tone])
            {
                pin.configure(PWM_OUT, params[0], params[1]);
                imp.sleep(params[2]);
            }
            pin.write(0);
        }
    }
        
    //**********************************************************
    // Continue playing an asynchronous sound. This is the 
    // callback that plays all notes after the first. 
    function _continueSound()
    {
        // Turn off the previous note
        pin.write(0);

        // This happens when playing more than one tone concurrently, 
        // which can happen if you scan again before the first tone
        // finishes.  Long term solution is to create a queue of notes
        // to play. 
        if (currentTone == null)
        {
            log("Error: tried to play null tone");
            return;
        }

        // Play the next note, if any
        if (tonesParamsList[currentTone].len() > currentToneIdx)
        {
            local params = tonesParamsList[currentTone][currentToneIdx];
           // local params1 = tonesParamsList[currentTone][currentToneIdx-1];
            pin.configure(PWM_OUT, params[0], params[1]);

            currentToneIdx++;
            imp.wakeup(params[2], _continueSound.bindenv(this));
        }
        else 
        {
            currentToneIdx = 0;
            currentTone = null;
        }
    }
}


//======================================================================
// Timer that can be canceled and executes a function when expiring
// Now that Electric Imp provides a timer handle each time you set a
// Timer, the CancellableTimer is now constructed to wake up for the set
// timer value instead of doing 0.5 seconds wakeup and checking for elapsed time
// This method significantly reduces the amount of timer interrupts fired
//
// New Method:
// If a timer object is created and enabled then it would use the duration to set the timer
// and retain the handle for it.  When the timer fires, it would call the action function
// if a timer needs to be cancelled, just call the disable function and it would disable the
// timer and set the handle to null.

class CancellableTimer
{
    actionFn = null; // Function to call when timer expires
    _timerHandle = null;
	duration = 0.0;

    //**********************************************************
    // Duration in seconds, and function to execute
    constructor(secs, func)
    {
        duration = secs;
        actionFn = func;
    }

    //**********************************************************
    // Start the timer
	// If the _timerHandle is null then no timer pending for this object
	// just create a timer and set it
    function enable() 
    {
        server.log("Timer enable called");
		
		if(_timerHandle)
		{
		  disable();
		}
		_timerHandle = imp.wakeup(duration,_timerCallback.bindenv(this));
    }

    //**********************************************************
    // Stop the timer
	// If the timer handle is not null then we have a pending timer, just cancel it
	// and set the handle to null
    function disable() 
    {
        server.log("Timer disable called!");
        // if the timerHandle is not null, then the timer is enabled and active
		if(_timerHandle)
		{
		  //just cancel the wakeup timer and set the handle to null
		  imp.cancelwakeup(_timerHandle);
		  _timerHandle = null;
		  server.log("Timer canceled wakeup!");
		}
    }
    
    //**********************************************************
    // Set new time for the timer
	// Expectation is that if an existing timer is pending
	// then the it needs to be disabled prior to setting the duration
	// Pre-Condition: timer is not running
	// Post-Condition: Timer is enabled
    function setDuration(secs) 
    {
		duration = secs;
    }
        

    //**********************************************************
    // Internal function to manage cancelation and expiration
    function _timerCallback()
    {
        server.log("timer fired!");
		actionFn();
		_timerHandle = null;
    }
}


//======================================================================
// Handles any I2C device
class I2cDevice
{
    i2cPort = null;
    i2cAddress = null;

    constructor(port, address)
    {
        i2cPort = port;

        // Use the fastest supported clock speed
        i2cPort.configure(CLOCK_SPEED_400_KHZ);

        // Takes a 7-bit I2C address
        i2cAddress = address << 1;
    }

    // Read a byte
    function read(register)
    {
        local data = i2cPort.read(i2cAddress, format("%c", register), 1);
        if(data == null)
        {
            log("Error: I2C read failure");
            // TODO: this should return null, right??? Do better handling.
            // TODO: print the i2c address as part of the error
            return -1;
        }

        return data[0];
    }
    
    function disable()
    {
    	SCL_OUT.configure(DIGITAL_IN_PULLUP);
    	SDA_OUT.configure(DIGITAL_IN_PULLUP);
    }

    // Write a byte
    function write(register, data)
    {
        if( i2cPort.write(i2cAddress, format("%c%c", register, data)) != 0)
        {
        	log(format("Error: I2C write failure on register=%04x",register));
        }
    }

    // Write a byte string
    function writeByteString(data)
    {
        
        if( i2cPort.write(i2cAddress, data) != 0)
        {
        	log("Error: I2C byte string write failure");
        }
    }
    
    // Read a byte string
    function readByteString(size)
    {
      local read_string = i2cPort.read(i2cAddress, "\x0b\x00", size);
      local num_string = "";
    
        if( read_string == null)
        {
        	log("Error: I2C byte string read failure");
        } else {
          for (local i=0; i<read_string.len(); i++)
            num_string += format("0x%02x ", read_string[i]);
          //server.log(format("Read byte string %s", num_string));
        }
        return read_string;
    }
}


//======================================================================
// Handles the SX1508 GPIO expander
class IoExpanderDevice
{

    intHandler = null;

    constructor(intHandler)
    {
        //base.constructor(port, address);
		this.intHandler = intHandler;

    }
    
    function getIntHandler()
    {
    	return this.intHandler;
    }

    // Write a bit to a register
    function writeBit(register, bitn, level)
    {
        local value = intHandler.getI2CDevice().read(register);
        value = (level == 0)?(value & ~(1<<bitn)):(value | (1<<bitn));
        intHandler.getI2CDevice().write(register, value);
    }

    // Write a masked bit pattern
    function writeMasked(register, data, mask)
    {
        local value = intHandler.getI2CDevice().read(register);
        value = (value & ~mask) | (data & mask);
        intHandler.getI2CDevice().write(register, value);
    }

    // Get a GPIO input pin level
    function getPin(gpio)
    {
        return (intHandler.getI2CDevice().read(0x08)&(1<<(gpio&7)))?1:0;
    }

    // Set a GPIO level
    function setPin(gpio, level)
    {
        writeBit(0x08, gpio&7, level?1:0);
    }

    // Set a GPIO direction
    function setDir(gpio, input)
    {
        writeBit(0x07, gpio&7, input?1:0);
    }

    // Set a GPIO internal pull up
    function setPullUp(gpio, enable)
    {
        writeBit(0x03, gpio&7, enable);
    }

    // Set a GPIO internal pull down
    function setPullDown(gpio, enable)
    {
        writeBit(0x04, gpio&7, enable);
    }

    // Set GPIO interrupt mask
    // "0" means disable interrupt, "1" means enable (opposite of datasheet)
    function setIrqMask(gpio, enable)
    {
        writeBit(0x09, gpio&7, enable?0:1); 
    }

    // Set GPIO interrupt edges
    function setIrqEdges(gpio, rising, falling)
    {
        local addr = 0x0B - (gpio>>2);
        local mask = 0x03 << ((gpio&3)<<1);
        local data = (2*falling + rising) << ((gpio&3)<<1);
        writeMasked(addr, data, mask);
    }
}


//======================================================================
// Device state machine 

//**********************************************************************
function updateDeviceState(newState)
{
    // Update the state 
    local oldState = gDeviceState;
    gDeviceState = newState;

    // If we are transitioning to idle, start the sleep timer. 
    // If transitioning out of idle, clear it.
    if (newState == DeviceState.IDLE)
    {
        if (oldState != DeviceState.IDLE)
        {
            gDeepSleepTimer.enable();
        }
    }
    else
    {
        // Disable deep sleep timer
        gDeepSleepTimer.disable();
        gAccelHysteresis.disable();
    }

    // If we are transitioning to SCAN_RECORD, start the button timer. 
    // If transitioning out of SCAN_RECORD, clear it. The reason 
    // we don't time the actual button press is that, if we have 
    // captured a scan, we don't want to abort.
    if (newState == DeviceState.SCAN_RECORD)
    {
        if (oldState != DeviceState.SCAN_RECORD)
        {
            // Start timing button press
            gButtonTimer.enable();
        }
    }
    else
    {
        // Stop timing button press
        gButtonTimer.disable();
    }

    // Log the state change, for debugging
    /*
    local os = (oldState==null) ? "null" : oldState.tostring();
    local ns = (newState==null) ? "null" : newState.tostring();
    log(format("State change: %s -> %s", os, ns));
    */
    // Verify state machine is in order 
    switch (newState) 
    {
        case DeviceState.IDLE:
            assert(oldState == DeviceState.BUTTON_RELEASED ||
            	   oldState == DeviceState.PRE_SLEEP ||
                   oldState == DeviceState.IDLE ||
                   oldState == null);
            break;
        case DeviceState.SCAN_RECORD:
            assert(oldState == DeviceState.IDLE ||
                   oldState == DeviceState.PRE_SLEEP );
            break;
        case DeviceState.SCAN_CAPTURED:
            assert(oldState == DeviceState.SCAN_RECORD);
            break;
        case DeviceState.BUTTON_TIMEOUT:
            assert(oldState == DeviceState.SCAN_RECORD);
            break;
        case DeviceState.BUTTON_RELEASED:
            assert(oldState == DeviceState.SCAN_RECORD ||
                   oldState == DeviceState.SCAN_CAPTURED ||
                   oldState == DeviceState.BUTTON_TIMEOUT);
            break;
        case DeviceState.PRE_SLEEP:
        	assert( oldState == DeviceState.IDLE ||
                    oldState == DeviceState.PRE_SLEEP);
        	break;
        default:
            assert(false);
            break;
    }
}


//======================================================================
// Scanner
class Scanner
{
    pin = null; // IO expander pin assignment (trigger)
    reset = null; // IO expander pin assignment (reset)
    scannerOutput = "";  // Stores the current barcode characters
    

    constructor(triggerPin, resetPin)
    {   
        //gInitTime.scanner = hardware.millis();

        // Save assignments
        pin = triggerPin;
        reset = resetPin;

	if (!is_hiku004) {
            // Reset the scanner at each boot, just to be safe
            ioExpander.setDir(reset, 0); // set as output
            ioExpander.setPullUp(reset, 0); // disable pullup
            ioExpander.setPin(reset, 0); // pull low to reset
            imp.sleep(0.001); // wait for x seconds
            ioExpander.setPin(reset, 1); // pull high to boot
            imp.sleep(0.001);

            // Configure trigger pin as output
            ioExpander.setDir(pin, 0); // set as output
            ioExpander.setPullUp(pin, 0); // disable pullup
            ioExpander.setPin(pin, 1); // pull high to disable trigger

            // Configure scanner UART (for RX only)
	    // WARNING: Ensure pin5 is never accidentally configured as a UART TX output
	    // and driven high. This triggers the buzzer and can cause device crashes
            // on a low battery.	
            SCANNER_UART.configure(38400, 8, PARITY_NONE, 1, NO_CTSRTS | NO_TX, 
                scannerCallback.bindenv(this));
            //gInitTime.scanner = hardware.millis() - gInitTime.scanner;
	}
    }

    // Disable for low power sleep mode
    function disable()
    {
	if (!is_hiku004) {
            ioExpander.setPin(reset, 0); // pull reset low 
            ioExpander.setPin(pin, 0); // pull trigger low 
            SCANNER_UART.disable();
            RXD_IN_FROM_SCANNER.configure(DIGITAL_IN_PULLUP);
            EIMP_AUDIO_IN.configure(DIGITAL_IN_PULLUP);
	}
    }

    function trigger(on)
    {
	if (is_hiku004) {
	    /*
	        if (on)
	           lymeric.writeByteString("\x01\x00\x03");
            else {
	           lymeric.writeByteString("\x01\x00\x00");
	           //lymeric.writeByteString("\x0B\x02");
	           lymeric.readByteString(65);
            }
            */
	}
	else {
            if (on)
		ioExpander.setPin(pin, 0);
            else
		ioExpander.setPin(pin, 1);
	}
    }

    //**********************************************************************
    // Start the scanner and sampler
    function startScanRecord() 
    {
        scannerOutput = "";
        // Trigger the scanner
        hwScanner.trigger(true);

        // Trigger the mic recording
        gAudioBufferOverran = false;
        gAudioChunkCount = 0;
        gLastSamplerBuffer = null; 
        gLastSamplerBufLen = 0; 
        agent.send("startAudioUpload", "");
        if (is_hiku004) {
            local pmic_val;
            packet_state.state = PS_OUT_OF_SYNC;
		    packet_state.char_string = "";
            //hardware.spiflash.enable();
            //server.log(format("Flash size: %d bytes", hardware.spiflash.size()));
            // HACK requires SCAN_DEBUG_SAMPLES * FLASH_BLOCK to be a multiple of BLOCKSIZE
            //for (local i=0; i<((SCAN_DEBUG_SAMPLES * FLASH_BLOCK)/BLOCKSIZE); i++)
            //  hardware.spiflash.erasesector(i*BLOCKSIZE);
            lines_scanned = 0;
            scan_byte_cnt = 0;
            scanner_error = false;
            //IMP_ST_CLK.configure(PWM_OUT, 0.000000125, 0.5);
            nrst.configure(DIGITAL_OUT);
            nrst.write(0);
            boot0.configure(DIGITAL_OUT);
            boot0.write(0);
            nrst.write(1);
            // turn on voltage to STM32F0
	        //pmic_val = pmic.read(0x00);
	        //pmic.write(0x00, pmic_val | 0x08);
            buf1.seek(0, 'b');
            buf2.seek(0, 'b');
            AUDIO_UART.disable();
            //AUDIO_UART.setrxfifosize(IMAGE_COLUMNS);
            //AUDIO_UART.setrxfifosize(UART_BUF_SIZE);
            //AUDIO_UART.configure(BAUD, 8, PARITY_NONE, 1, NO_CTSRTS | NO_TX, audioUartCallback);
            AUDIO_UART.configure(1843200, 8, PARITY_NONE, 1, NO_CTSRTS | NO_TX, audioUartCallback);
            //AUDIO_UART.configure(1843200, 8, PARITY_NONE, 1, NO_CTSRTS | NO_TX, scannerDebugCallback); 
            gAudioTimer = hardware.millis();
        } else
            hardware.sampler.start();
    }

    //**********************************************************************
    // Stop the scanner and sampler
    // Note: this function may be called multiple times in a row, so
    // it must support that. 
    function stopScanRecord()
    {
        if (is_hiku004) {
            audioUartCallback();
            //local pmic_val;
            AUDIO_UART.disable();
            // turn off voltage to STM32F0
	        //pmic_val = pmic.read(0x00);
	        //pmic.write(0x00, pmic_val & 0xF7);
            nrst.write(0);
            //IMP_ST_CLK.configure(DIGITAL_IN);
            /*
            lines_scanned = scan_byte_cnt/IMAGE_COLUMNS;
            agent.send("scan_start", null);
            server.log(format("Fetching %d lines", lines_scanned));
            for (local i=0; i<lines_scanned; i++) {
              agent.send("scan_line", hardware.spiflash.read(i*IMAGE_COLUMNS, IMAGE_COLUMNS));
            }
            server.log("Lines fetched!");
            for (local i=0; i<((SCAN_DEBUG_SAMPLES * FLASH_BLOCK)/BLOCKSIZE); i++)
              hardware.spiflash.erasesector(i*BLOCKSIZE);
              */
            //hardware.spiflash.disable();
        } else
            // Stop mic recording
            hardware.sampler.stop();

        // Release scanner trigger
        hwScanner.trigger(false);

        // Reset for next scan
        scannerOutput = "";
    }

    //**********************************************************************
    // Scanner data ready callback, called whenever there is data from scanner.
    // Reads the bytes, and detects and handles a full barcode string.
    function scannerCallback()
    {
        // Read the first byte
        local data = (is_hiku004 ? AUDIO_UART : SCANNER_UART).read();
        while (data != -1)  
        {
            //log("char " + data + " \"" + data.tochar() + "\"");

            // Handle the data
            switch (data) 
            {
                case '\n':
                    // Scan complete. Discard the line ending,
                    // upload the beep, and reset state.

                    // If the scan came in late (e.g. after button up), 
                    // discard it, to maintain the state machine. 
                    if (gDeviceState != DeviceState.SCAN_RECORD)
                    {
                    	/*
                        log(format(
                                   "Got capture too late. Dropping scan %d",
                                   gDeviceState)); */
                        scannerOutput = "";
                        return;
                    }
                    updateDeviceState(DeviceState.SCAN_CAPTURED);
                    /*log("Code: \"" + scannerOutput + "\" (" + 
                               scannerOutput.len() + " chars)");*/
                    //determineSetupBarcode(scannerOutput);
                    if(0!= agent.send("uploadBeep", {
                                              scandata=scannerOutput,
                                              scansize=scannerOutput.len(),
                                              serial=hardware.getdeviceid(),
                                              fw_version=cFirmwareVersion,
                                              linkedrecord="",
                                              audiodata="",
                                             }))
                    {

                    }
                    else
                    {
                    	hwPiezo.playSound("success-local");
                    }
                    
                    // Stop collecting data
                    stopScanRecord();
                    break;

                case '\r':
                    // Discard line endings
                    break;

                default:
                    // Store the character
                    scannerOutput = scannerOutput + data.tochar();
                    break;
            }

            // Read the next byte
            data = (is_hiku004 ? AUDIO_UART : SCANNER_UART).read();
        } 
    }
}


//======================================================================
// Button
enum ButtonState
{
    BUTTON_UP,
    BUTTON_DOWN,
}

class PushButton
{
    pin = null; // IO expander pin assignment
    buttonState = ButtonState.BUTTON_UP; // Button current state
    
    buttonPressCount = 0;
    previousTime = 0;
    blinkTimer = null;
    
    connection = false;

    // WARNING: increasing these can cause buffer overruns during 
    // audio recording, because this the button debouncing on "up"
    // happens before the audio sampler buffer is serviced. 
    //static numSamples = 5; // For debouncing
   // static sleepSecs = 0.004;  // For debouncing

    constructor(btnPin)
    {   
		//gInitTime.button = hardware.millis();
		
        // Save assignments
        pin = btnPin;

        // Set event handler for IRQ
        intHandler.setIrqCallback(btnPin, buttonCallback.bindenv(this));
	if (is_hiku004)
	    BTN_N.configure(DIGITAL_IN, buttonCallback.bindenv(this));
        connMgr.registerCallback(connectionStatusCb.bindenv(this));

	if (!is_hiku004) {
            // Configure pin as input, IRQ on both edges
            ioExpander.setDir(pin, 1); // set as input
            ioExpander.setPullUp(pin, 1); // enable pullup
            ioExpander.setIrqMask(pin, 1); // enable IRQ
            ioExpander.setIrqEdges(pin, 1, 1); // rising and falling
	}
        
        blinkTimer = CancellableTimer(BLINK_UP_TIME, this.cancelBlinkUpTimer.bindenv(this));
        
        connection = connection_available;
    }
    
    function connectionStatusCb(status)
    {
		connection = (status == SERVER_CONNECTED);
    	if((connection) && ( buttonState == ButtonState.BUTTON_DOWN ) )
    	{
            updateDeviceState(DeviceState.SCAN_RECORD);
            buttonState = ButtonState.BUTTON_DOWN;
            //log("Button state change: DOWN");
            hwScanner.startScanRecord();    		
    	}
    }

    function readState()
    {
	if (is_hiku004) 
	    return BTN_N.read() 
	else
            return ioExpander.getPin(pin);
    }

    //**********************************************************************
    // If we are gathering data and the button has been held down 
    // too long, we abort recording and scanning.
    function handleButtonTimeout()
    {
        updateDeviceState(DeviceState.BUTTON_TIMEOUT);
        hwScanner.stopScanRecord();
        hwPiezo.playSound("timeout");
        log("Timeout reached. Aborting scan and record.");
    }

    //**********************************************************************
    // Button handler callback 
    // Not a true interrupt handler, this cannot interrupt other Squirrel 
    // code. The event is queued and the callback is called next time the 
    // Imp is idle.
    function buttonCallback()
    {
        // Sample the button multiple times to debounce. Total time 
        // taken is (numSamples-1)*sleepSecs
        local state = readState();
        local curr_time, delta;
        

		imp.sleep(0.020);
        state += readState();

		//log("buttonCallBack entry time: " + hardware.millis() + "ms");

        // Handle the button state transition
        switch(state) 
        {
            case 0:
            	/*
                // Button in held state
                if( hwPiezo.isPaging() )
                {
                	hwPiezo.stopPageTone();
                }
                */
                
                // The logic below is to ensure
                // that we are able to enter
                // blink-up state with BLINK_UP_BUTTON_COUNT quick button presses
                curr_time = hardware.millis();
                local prv_time = previousTime;
        		previousTime = curr_time;
        		delta = curr_time - prv_time;
                buttonPressCount = ( delta <= 300 )?++buttonPressCount:0;
                
                if ((BLINK_UP_BUTTON_COUNT-1 == buttonPressCount))
                {
                	blinkUpDevice(true);
                	buttonPressCount = 0;
                	return;
                }
                
                if( delta <= 300 )
                {
                	return;
                }
                
                //log(format("buttonPressCount=%d",buttonPressCount));                
                
                if (buttonState == ButtonState.BUTTON_UP)
                {
                 	if(!connection)
                	{
                		// Here we play the no connection sound and return from the state machine
                		if( !nv.setup_required )
                		{
                			hwPiezo.playSound("no-connection");
                		}
                		//buttonState = ButtonState.BUTTON_DOWN;
                		return;
                	}
		    agentSend("button","Pressed");
                    updateDeviceState(DeviceState.SCAN_RECORD);
                    buttonState = ButtonState.BUTTON_DOWN;
                    //log("Button state change: DOWN");
                    hwScanner.startScanRecord();
                }
		else
		{
		    buttonState = ButtonState.BUTTON_DOWN;
		}
                
                break;
            case 2:
                // Button in released state
                if (buttonState == ButtonState.BUTTON_DOWN)
                {
		    server.log("BUTTON RELEASED!");
		    agentSend("button","Released");
                    buttonState = ButtonState.BUTTON_UP;
                    //log("Button state change: UP");
				    /*
					if( !connection )
					{
						return;
					}
				    */
                    local oldState = gDeviceState;
                    updateDeviceState(DeviceState.BUTTON_RELEASED);

                    if (oldState == DeviceState.SCAN_RECORD)
                    {
                        // Audio captured. Stop sampling and send it. 
                        // Note that we only call sendLastBuffer in
                        // the case that we want to capture the audio, 
                        // so it cannot be inside stopScanRecord, which 
                        // is called in multiple places. 
                        // We have two uses of imp.onidle(), one during 
                        // the IDLE state and one when not idle.  They 
                        // must be kept separate, as only one onidle 
                        // callback is supported at a time. 
                        gSamplerStopping = true;
                        imp.onidle(sendLastBuffer); 
                        hwScanner.stopScanRecord();
                    }
                    // No more work to do, so go to idle
                    updateDeviceState(DeviceState.IDLE);
                }
                break;
            default:
                // Button is in transition (not settled)
                //log("Bouncing! " + buttonState);
                break;
        }
        //log("buttonCallBack exit time: " + hardware.millis() + "ms");
    }
    
    function blinkUpDevice(blink=false)
    {
    	if( blink )
    	{
    		hwPiezo.playSound("blink-up-enabled");
    		//Enable the 5 minute Timer here
    		// Ensure that we only enable it for the setup_required case
    		if( !server.isconnected())
    		{
    			nv.setup_required = true;
    			nv.sleep_not_allowed = true;
				blinkTimer.disable();
    			blinkTimer.enable();
    		}
    	}
    	log(format("Blink-up: %s.",blink?"enabled":"disabled"));
    }
    
    function cancelBlinkUpTimer()
    {
    	nv.sleep_not_allowed = false;
    }
}


//======================================================================
// Charge status pin
class ChargeStatus
{
    pin = null; // IO expander pin assignment
    previous_state = false; // the previous state of the charger
    pinStatus = null; // IO Expander Pin 7 for Charger Status

    constructor(chargePin)
    {
        // Save assignments
        pin = chargePin;
	pinStatus = 7;

        // Set event handler for IRQ
        intHandler.setIrqCallback(pin, chargerCallback.bindenv(this));
        intHandler.setIrqCallback(pinStatus, chargerDetectionCB.bindenv(this));
	if (is_hiku004)
	    CHARGER_INT_N.configure(DIGITAL_IN, chargerDetectionCB.bindenv(this));
        
	BATT_VOLT_MEASURE.configure(ANALOG_IN);

	if (!is_hiku004) {
            // Configure pin as input, IRQ on both edges
            ioExpander.setDir(pin, 1); // set as input
            ioExpander.setPullUp(pin, 1); // enable pullup
            ioExpander.setIrqMask(pin, 1); // enable IRQ
            ioExpander.setIrqEdges(pin, 1, 1); // rising and falling
            
            ioExpander.setDir(pinStatus, 1); // set as input
            ioExpander.setPullUp(pinStatus, 1); // enable pullup
            ioExpander.setIrqMask(pinStatus, 1); // enable IRQ
            ioExpander.setIrqEdges(pinStatus, 1, 1); // rising and falling
	}

	chargerCallback(); // this will update the current state right away
        imp.wakeup(5, batteryMeasurement.bindenv(this));
    }
    
    function isCharging()
    {
	local charge_detect_n;

	if (is_hiku004) 
	    // HACK replace CHARGER_INT_N.read() for charging start/stop with I2C call to LP3918 or monitoring of charging current (IMON)
	    charge_detect_n = CHARGER_INT_N.read();
	else
	    charge_detect_n = ioExpander.getPin(pin);

        return (charge_detect_n ? false : true);
    }
    
    function batteryMeasurement()
    {
    	local raw_read = 0.0;
    	
    	for(local i = 0; i < 10; i++)
    	    raw_read += BATT_VOLT_MEASURE.read();
    	
    	raw_read = (raw_read / 10.0);
    	nv.voltage_level = raw_read;
    	
    	// every 15 seconds wake up and read the battery level
    	// TODO: change the period of measurement so that it doesn�t drain the
    	// battery
    	//log(format("Battery Level: %d, Input Voltage: %.2f", nv.voltage_level, hardware.voltage()));
    	imp.wakeup(1, function() {
    		agentSend("batteryLevel", nv.voltage_level)
    	});
    	imp.wakeup(60, batteryMeasurement.bindenv(this));
    }
    
    function chargerDetectionCB()
    {
    	// the pin is high charger is attached and low is a removal
	local charge_detect_n;

	if (is_hiku004)
		charge_detect_n = CHARGER_INT_N.read();
	    else
		charge_detect_n = ioExpander.getPin(7);

	local status = charge_detect_n ? "disconnected":"connected";

    	log(format("USB Detection CB: %s", status));
        server.log(format("USB Detection CB: %s", status));
	agentSend("usbState",status);
    }

    //**********************************************************************
    // Charge status interrupt handler callback 
    function chargerCallback()
    {
        local charging = 0;
        
        charging = isCharging()?1:0;
        
        //Total time taken is (numSamples-1)*sleepSecs
        for (local i=1; i<5; i++)
        {
            charging += isCharging()?1:0;
        }
        //log(format("Charger: %s",charging?"charging":"not charging"));
        
		if( previous_state != (charging==0?false:true))
		{
            hwPiezo.playSound(previous_state?"charger-attached":"charger-removed");
        }
		
        previous_state = (charging==0)? false:true; // update the previous state with the current state
        agentSend("chargerState", previous_state); // update the charger state

	local charge_detect_n;

	if (is_hiku004)
		charge_detect_n = CHARGER_INT_N.read();
	    else
		charge_detect_n = ioExpander.getPin(7);

	local status = charge_detect_n ? "disconnected":"connected";

        log(format("USB Detection: %s", status));
	server.log(format("USB Detection: %s", status));
    }
}

//======================================================================
// Sampler/Audio In

//**********************************************************************
// Agent callback: upload complete
agent.on("uploadCompleted", function(result) {
	//log("uploadCompleted response");
    hwPiezo.playSound(result);
});

/*
agent.on("devicePage", function(result){
	hwPiezo.playPageTone();
});*/


//**********************************************************************
// Process the last buffer, if any, and tell the agent we are done. 
// This function is called after sampler.stop in a way that 
// ensures we have captured all sampled buffers. 
function sendLastBuffer()
{
    // Send the last chunk to the server, if there is one
    if (gLastSamplerBuffer != null && gLastSamplerBufLen > 0)
    {
        agent.send("uploadAudioChunk", {buffer=gLastSamplerBuffer, 
                   length=gLastSamplerBufLen});
    }

    // If there are less than x secs of audio, abandon the 
    // recording. Else send the beep!
    local secs;
    if (is_hiku004)
        secs = (hardware.millis()-gAudioTimer)/1000.0;
    else
        secs = gAudioChunkCount*gAudioBufferSize/
               gAudioSampleRate.tofloat();

    //Because we cannot guarantee network robustness, we allow 
    // uploads even if an overrun occurred. Worst case it still
    // fails to reco, and you'll get an equivalent error. 
    //if (secs >= 0.4 && !gAudioBufferOverran)
    if (secs >= 0.4)
    {
        if(agent.send("endAudioUpload", {
                                      scandata="",
                                      serial=hardware.getdeviceid(),
                                      fw_version=cFirmwareVersion,
                                      linkedrecord="",
                                      audiodata="", // to be added by agent
                                      scansize=gAudioChunkCount, 
                                     }) == 0)
        {
        	hwPiezo.playSound("success-local");
        }
    } else {
        agent.send("abortAudioUpload", {
                                      scandata="",
                                      serial=hardware.getdeviceid(),
                                      fw_version=cFirmwareVersion,
                                      linkedrecord="",
                                      audiodata="", // to be added by agent
                                      scansize=gAudioChunkCount, 
                                     });
    }

    // We have completed the process of stopping the sampler
    gSamplerStopping = false;
}


//**********************************************************************
// Called when an audio sampler buffer is ready.  It is called 
// ((sample rate * bytes per sample)/buffer size) times per second.  
// So for 16 kHz sampling of 8-bit A law and 2000 byte buffers, 
// it is called 8x/sec. 
// 
// Since A-law seems to only send full buffers, we send the whole 
// buffer and truncate if necessary on the server side, instead 
// of making a (possibly truncated) copy each time here. This 
// is filed as a bug that may be fixed in the future. 
// 
// Buffer overruns can be caused (and typically are) by this routine
// taking too long.  It typically takes too long if the network is slow
// or flakey when we upload samples.  We are robust if this callback
// takes up to about 100ms.  Typically it should take about 3ms.  

function samplerCallback(buffer, length)
{
    //log("SAMPLER CALLBACK: size " + length");
    if (length <= 0)
    {
        gAudioBufferOverran = true;
        log("Error: audio sampler buffer overrun!!!!!!, last timer="+gAudioTimer+"ms, free-mem:"+imp.getmemoryfree()+", rssi: "+imp.rssi());
        
    }
    else 
    {
        // Time the sending
        gAudioChunkCount++;
        gAudioTimer = hardware.millis();

        // Send the data, managing the last buffer as a special case
        if (gSamplerStopping) {
            if (gLastSamplerBuffer) { 
                // It wasn't quite the last one, send normally
                agent.send("uploadAudioChunk", {buffer=buffer, 
                           							length=length});
            }
            // Process last buffer later, to do special handling
            gLastSamplerBuffer = buffer;
            gLastSamplerBufLen = length;
        }
        else
        {
            server.log(format("About to send an audio chunck of size: %d",length));
            server.log(format("Agent Send Response: %d", agent.send("uploadAudioChunk", {buffer=buffer, length=length})));
        }

        // Finish timing the send.  See function comments for more info. 
        gAudioTimer = hardware.millis() - gAudioTimer;
        //log(gAudioTimer + "ms");
    }
}

function audioUartCallback()
{
    local buf_ptr = 0;
    local string_len;
    
    packet_state.char_string += AUDIO_UART.readstring(UART_BUF_SIZE);
    string_len = packet_state.char_string.len();

    while ((buf_ptr < string_len) && (packet_state.state < PS_TYPE_FIELD)) {
        if (packet_state.char_string[buf_ptr] == PS_PREAMBLE[packet_state.state])
          packet_state.state++;
        else if (packet_state.char_string[buf_ptr] == PS_PREAMBLE[0])
            packet_state.state = 1;
          else
            packet_state.state = 0;
        buf_ptr++;
    }
   if ((buf_ptr < string_len) && (packet_state.state == PS_TYPE_FIELD)) {
      packet_state.type = packet_state.char_string[buf_ptr];
      packet_state.state++;
      buf_ptr++;
   }
   if ((buf_ptr < string_len) && (packet_state.state == PS_LEN_FIELD)) {
      // HACK HACK HACK
      // verify that length is not 0
      packet_state.pay_len = packet_state.char_string[buf_ptr];
      packet_state.state++;
      buf_ptr++;
   }
   if ((string_len-buf_ptr >= packet_state.pay_len) && (packet_state.state == PS_DATA_FIELD)) {
       switch (packet_state.type) {
           case PKT_TYPE_AUDIO:
               audio_pkt_blob.seek(0,'b');
               audio_pkt_blob.writestring(packet_state.char_string.slice(buf_ptr, buf_ptr+packet_state.pay_len));
               agent.send("uploadAudioChunk", {buffer=audio_pkt_blob, length=packet_state.pay_len});
               //server.log(audio_pkt_blob);
               buf_ptr += packet_state.pay_len;
               break;
           case PKT_TYPE_SCAN:
                    local scannerOutput = "";
                    // If the scan came in late (e.g. after button up), 
                    // discard it, to maintain the state machine. 
                    if (gDeviceState != DeviceState.SCAN_RECORD)
                      return;
                    updateDeviceState(DeviceState.SCAN_CAPTURED);
                    while ((buf_ptr < string_len) && (packet_state.char_string[buf_ptr] != '\r')) {
                        scannerOutput += packet_state.char_string[buf_ptr].tochar();
                        buf_ptr++;
                    }
                    if (packet_state.char_string[buf_ptr] != '\r')
                      return;
                    server.log(format("Scanned %s", scannerOutput));
                    if(agent.send("uploadBeep", {
                                              scandata=scannerOutput,
                                              scansize=scannerOutput.len(),
                                              serial=hardware.getdeviceid(),
                                              fw_version=cFirmwareVersion,
                                              linkedrecord="",
                                              audiodata="",
                                             }) == 0)
                    	hwPiezo.playSound("success-local");
                    // Stop collecting data
                    hwScanner.stopScanRecord();
               break;
           default:
               buf_ptr += packet_state.pay_len;
               break;
       }
      packet_state.state = PS_OUT_OF_SYNC;
   }

/*
   if (packet_state.state == PS_LEN_FIELD+1) {
       server.log("Preamble found!");
       server.log(format("ptr 0x%x type 0x%x len 0x%x", buf_ptr, packet_state.type, packet_state.pay_len));
       packet_state.state = 0;
   }
*/
   packet_state.char_string = packet_state.char_string.slice(buf_ptr);
}

function scannerDebugCallback()
{
    if (scan_byte_cnt < SCAN_MAX_BYTES) {
    buf1.writeblob(AUDIO_UART.readblob(IMAGE_COLUMNS));
    local bytes_read = buf1.tell();
    
    //if (bytes_ == IMAGE_COLUMNS) {
        //hardware.spiflash.write(lines_scanned*FLASH_BLOCK, buf1, 0, 0, IMAGE_COLUMNS-1);
        hardware.spiflash.write(scan_byte_cnt, buf1);
        scan_byte_cnt += bytes_read;
        //lines_scanned++;
        //server.log("X");
        buf1.seek(0,'b');
    if (!scanner_error && (bytes_read % IMAGE_COLUMNS != 0)) {
        scanner_error = true;
        server.log(format("Scanner error during UART RX, %d", bytes_read));
    }
        /*
    } else if (buf1.tell() > IMAGE_COLUMNS) {
        scanner_error = true;
        server.log(format("Scanner error during UART RX, %d", buf1.tell()));
    } else 
        server.log(format("Scanner UART RX, partial buffer %d", buf1.tell()));
    } else {
      AUDIO_UART.readblob(IMAGE_COLUMNS);
      AUDIO_UART.disable();
    }*/
    }
}


//======================================================================
// Accelerometer

// Accelerometer I2C device
class Accelerometer extends I2cDevice
{
    i2cPort = null;
    i2cAddress = null;
    interruptDevice = null; 
    reenableInterrupts = false;  // Allow interrupts to be re-enabled after 
                                 // an interrupt

    constructor(port, address, pin)
    {
        base.constructor(port, address);
        
        //gInitTime.accel = hardware.millis();

        // Verify communication by reading WHO_AM_I register
        local whoami = read(0x0F);
        if (whoami != 0x33)
        {
            log(format("Error reading accelerometer; whoami=0x%02X", 
                              whoami));
        }
		
		write( 0x1F, 0x0 ); // disable ADC and temp sensor
		
		whoami = read( 0x1E );
		write ( 0x1E, whoami | 0x80 );

        // Configure and enable accelerometer and interrupt
        write(0x20, 0x2F); // CTRL_REG1: 10 Hz, low power mode, 
                             // all 3 axes enabled

        write(0x21, 0x09); // CTRL_REG2: Enable high pass filtering and data

        //enableInterrupts();
        disableInterrupts();

        write(0x23, 0x00); // CTRL_REG4: Default related control settings

        write(0x24, 0x08); // CTRL_REG5: Interrupt latched

        // Note: maximum value is 0111 11111 (0x7F). High bit must be 0.
        write(0x32, 0x10); // INT1_THS: Threshold

        write(0x33, 0x1); // INT1_DURATION: any duration

        // Read HP_FILTER_RESET register to set filter. See app note 
        // section 6.3.3. It sounds like this might be the REFERENCE
        // register, 0x26. Commented out as I found it is not needed. 
        //read(0x26);

        write(0x30, 0x2A); // INT1_CFG: Enable OR interrupt for 
                           // "high" values of X, Y, Z
                           
        

        // Clear interrupts before setting handler.  This is needed 
        // otherwise we get a spurious interrupt at boot. 
        clearAccelInterrupt();

	if (!is_hiku004) {
            // Configure pin as input, IRQ on both edges
            ioExpander.setDir(pin, 1); // set as input
            ioExpander.setPullDown(pin, 1); // enable pulldown
            ioExpander.setIrqMask(pin, 1); // enable IRQ
            ioExpander.setIrqEdges(pin, 1, 0); // rising only        
	}
        // Set event handler for IRQ
        intHandler.setIrqCallback(pin, handleAccelInt.bindenv(this));
	if (is_hiku004)
	    ACCEL_INT.configure(DIGITAL_IN, handleAccelInt.bindenv(this));
    }

    function enableInterrupts()
    {
    	write(0x20, 0x2F); // power up first
        write(0x22, 0x40); // CTRL_REG3: Enable AOI interrupts
    }

    function disableInterrupts()
    {
    	write(0x20, 0x0F); // power down
        write(0x22, 0x00); // CTRL_REG3: Disable AOI interrupts
    }

    function clearAccelInterruptUntilCleared()
    {
        // Repeatedly clear the accel interrupt by reading INT1_SRC
        // until there are no interrupts left
        // WARNING: adding log statements in this function
        // causes it to fail for some reason
        local reg;
        while ((reg = read(0x31)) != 0x15)
        {
        	//log(format("STATUS: 0x%02X", reg));
            imp.sleep(0.001);
        }
        log(format("STATUS: 0x%02X", reg));
        
    }

    function clearAccelInterrupt()
    {
        read(0x31); // Clear the accel interrupt by reading INT1_SRC
    }

    function handleAccelInt() 
    {
        gAccelInterrupted = true;
        disableInterrupts();
        clearAccelInterrupt();
        if(reenableInterrupts)
        {
            enableInterrupts();
        }
    }
}


//======================================================================
// Utilities

//**********************************************************************

//**********************************************************************
// Temporary function to catch dumb mistakes
function print(str)
{
    log("ERROR USED PRINT FUNCTION. USE SERVER.LOG INSTEAD.");
}


//**********************************************************************
function init_nv_items()
{
	log(format("sleep_count=%d setup_required=%s", 
					nv.sleep_count, (nv.setup_required?"yes":"no")));
	//server.log(format("Bootup Reason: %xh", nv.boot_up_reason));
}

function init_unused_pins(i2cDev)
{
	//gInitTime.init_unused = hardware.millis();
	local value = 0;
	
	//1. Set Direction to Input for PIN 3 and 7
	value = i2cDev.read(0x07);
	i2cDev.write(0x07, (value | (1 << (3 & 7)) | (1 << ( 7 & 7))));
	
	//2. Set Pull up for PIN 3 and 7
	value = i2cDev.read( 0x03 );
	i2cDev.write(0x03, (value | (1 << (3 & 7)) | (1 << ( 7 & 7))));
	
	//3. setIRQ Mask to disable interrupts on 3 and 7
	value = i2cDev.read( 0x09 );
	i2cDev.write(0x09, value | ( 0xF8 ));
	
	hardware.pinA.configure(DIGITAL_IN_PULLUP);
	hardware.pin6.configure(DIGITAL_IN_PULLUP);
	hardware.pinB.configure(DIGITAL_IN_PULLUP);
	hardware.pinC.configure(DIGITAL_IN_PULLUP);
	hardware.pinD.configure(DIGITAL_IN_PULLUP);
	hardware.pinE.configure(DIGITAL_IN_PULLUP);
	
	//gInitTime.init_unused = hardware.millis() - gInitTime.init_unused;
}

//**********************************************************************
// Do pre-sleep configuration and initiate deep sleep
function preSleepHandler() {
	updateDeviceState( DeviceState.PRE_SLEEP);

    // Resample the ~CHG charge signal and update chargeStatus.
	// previous_state before going to sleep 
	chargeStatus.chargerCallback();
	
	if( nv.sleep_not_allowed || chargeStatus.previous_state )
	{
		//Just for testing but we should remove it later
		//hwPiezo.playSound("device-page");
		updateDeviceState( DeviceState.IDLE );
		return;
	}
	
	if( !nv.setup_required )
	{
    	// Re-enable accelerometer interrupts
    	log("preSleepHandler: about to re-enable accel Intterupts");
    	hwAccelerometer.reenableInterrupts = true;
    	hwAccelerometer.enableInterrupts();

    	// Handle any last interrupts before we clear them all and go to sleep
    	log("preSleepHandler: handle any pending interrupts");
    	intHandler.handlePin1Int(); 
		log("preSleepHandler: handled pending interrupts");
    	// Clear any accelerometer interrupts, then clear the IO expander. 
    	// We found this to be necessary to not hang on sleep, as we were
    	// getting spurious interrupts from the accelerometer when re-enabling,
    	// that were not caught by handlePin1Int. Race condition? 
    	log("preSleepHandler: clear out all the pending accel interrupts");
    	hwAccelerometer.clearAccelInterruptUntilCleared();
	if (!is_hiku004) {
    	    log("preSleepHandler: clear out all the IOExpander Interrupts");
    	    intHandler.clearAllIrqs(); 
	}
    
    	// When the timer below expires we will hit the sleepHandler function below
    	// only enter into the delay wait if the current state is either IDLE or PRE_SLEEP
    	// otherwise just get out of this because it would just go into sleep even though
    	// someone pushed the button
    	if( (gDeviceState == DeviceState.IDLE) || (gDeviceState == DeviceState.PRE_SLEEP) )
    	{
    		gAccelInterrupted = false;
    		log("preSleepHandler: enabled the hysteresis timer");
    		gAccelHysteresis.enable();
    	}
    }
    else
    {
    	// If the setup is required and we timed out for
    	// the 5 minute timer then we just enter sleep right away
    	// only thing that would wake up the device is the button press
    	gAccelInterrupted = false;
    	sleepHandler();
    }
}


function configurePinsBeforeSleep()
{

    // Disable the scanner and its UART
    hwScanner.disable();
    hwPiezo.disable();
     
    if (!is_hiku004) {
	// set all registers on the SX1508 pin expander to defined values before sleep

	// set registers RegInputDisable, RegLongSlew, RegLowDrive to default values
	i2cDev.write(0x00, 0x00);
	i2cDev.write(0x01, 0x00);
	i2cDev.write(0x02, 0x00);
	// enable the pullup resistor for the button (BUTTON_L) and to disable 
	// microphone and scanner (SW_VCC_EN_L)
	i2cDev.write(0x03, 0x14);
	// set registers RegPullDown, RegOpenDrain, and RegPolarity to default values
	i2cDev.write(0x04, 0x00);
	i2cDev.write(0x05, 0x00);
	i2cDev.write(0x06, 0x00);
	// set all pins on the SX1508 to inputs
	i2cDev.write(0x07, 0xff);
	// set output values in RegData to default values
	i2cDev.write(0x08, 0xff);
	// enable interrupts for button (BUTTON_L), accelerometer (ACCELEROMETER_INT), and charger (CHARGE_PGOOD_L)
	i2cDev.write(0x09, 0x7a);
	// set interrupt trigger to both edges for the enabled interrupts
	i2cDev.write(0x0a, 0xc0);
	i2cDev.write(0x0b, 0x33);
	// clear all interrupts
	i2cDev.write(0x0c, 0xff);    
	i2cDev.write(0x0d, 0xff);

	i2cDev.disable();
    }
}

//**********************************************************************
// This is where we want to actually enter sleep if there aren�t any 
// further accelerometer interrupts
function sleepHandler()
{
 	log("sleepHandler: enter");   
    if( gAccelInterrupted )
    {
		log("sleepHandler: aborting sleep due to Accelerometer Interrupt");
		// Transition to the idle state
		hwAccelerometer.reenableInterrupts = false;
		hwAccelerometer.disableInterrupts();
		updateDeviceState(DeviceState.IDLE);
		return;
    }
    
	// free memory
    log(format("Free memory: %d bytes", imp.getmemoryfree()));
    
    assert(gDeviceState == DeviceState.PRE_SLEEP);
    log(format("sleepHandler: entering deep sleep, hardware.pin1=%d", CPU_INT.read()));
    server.expectonlinein(nv.setup_required?cDeepSleepInSetupMode:cDeepSleepDuration);
    nv.sleep_count++;
    nv.boot_up_reason = 0x0;
    nv.sleep_duration = time();
    server.disconnect();
    
    configurePinsBeforeSleep();
    // NOTE: disabling blinkup before sleep is required for hiku-004
    // as the Imp otherwise starts flashing the LEDs green/red/yellow when
    // going to sleep
    imp.enableblinkup(false);
    imp.setpoweren(false);
    imp.deepsleepfor(nv.setup_required?cDeepSleepInSetupMode:cDeepSleepDuration);   
}


//**********************************************************************
// main

function init_done()
{
	if( init_completed )
	{
		intHandler.handlePin1Int(); 
		//log(format("init_stage1: %d\n", gInitTime.init_stage1));
		
		// Since the blinkup is always enabled, there is no need to enable
		// them here
		if( nv.setup_required )
		{
		  hwButton.blinkUpDevice(nv.setup_required);
		}
	}
	else
	{
		imp.wakeup(1, init_done );
	}
}

// This is the log function wrapper
// so that we can 
function log(str)
{
	//server.log(str);
    agentSend("deviceLog", str);
}

function agentSend(key, value)
	{
  if(server.isconnected())
  {
    if(agent.send(key,value) != 0)
    {
	  server.log(format("agentSend: failed for %s",key));
	}
}
}

triggerCount <- 0;
function shippingMode(){
    hwScanner.trigger(triggerCount % 2 == 0);
    triggerCount++;
    if (triggerCount < 40)
	imp.wakeup(0.05, shippingMode);
    else {
	   hwPiezo.playSound("blink-up-enabled", false);
	   nv.setup_required = true;
    	   nv.sleep_not_allowed = false;
    	   gAccelInterrupted = false;
	   gDeviceState = DeviceState.PRE_SLEEP;
	   triggerCount = 0;
	   imp.clearconfiguration();
    	   sleepHandler();
    }
}

agent.on("shippingMode", function(result) {
	if (imp.getbssid() == FACTORY_BSSID)
	    shippingMode();
});

function init()
{
    // We will always be in deep sleep unless button pressed, in which
    // case we need to be as responsive as possible. 
    imp.setpowersave(false);
	//gInitTime.init_stage1 = hardware.millis();
    // I2C bus addresses
    //const cAddrAccelerometer = 0x18;

    // IO expander pin assignments
    //const cIoPinAccelerometerInt = 0;
    //const cIoPinChargeStatus = 1;
    //const cIoPinButton =  2;
    //const cIoPin3v3Switch =  4;
    //const cIoPinScannerTrigger =  5;
    //const cIoPinScannerReset =  6;
    if (is_hiku004) {
    local pmic_val;
	i2cDev <- null;
	// create device for LP3918 power management IC
	pmic <- I2cDevice(I2C_IF, 0x7e);
	// set buzzer volume by setting LDO1 voltage to 3.0V
	pmic.write(0x01, 0x0b);
	// set charging current to 500mA
	pmic.write(0x11, 0x9);
	// wait 350ms after release of PS_HOLD before turning off power
	pmic.write(0x1c, 0x1);
    // turn on voltage to STM32F0
	pmic_val = pmic.read(0x00);
	pmic.write(0x00, pmic_val | 0x08);


	lymeric <- I2cDevice(I2C_IF, 0x41);
	
    }
    else 
	// Create an I2cDevice to pass around
	i2cDev <- I2cDevice(I2C_IF, 0x23);

    intHandler <- InterruptHandler(8, i2cDev);	
    
    if (!is_hiku004) {
	ioExpander <- IoExpanderDevice(intHandler);
	
	// This is to default unused pins so that we consume less current
	init_unused_pins(i2cDev);
    
	// 3v3 accessory switch config
	// we don�t need a class for this:	
	// Configure pin 
	ioExpander.setDir(4, 0); // set as output
	ioExpander.setPullUp(4, 0); // disable pullup
	ioExpander.setPin(4, 0); // pull low to turn switch on
	ioExpander.setPin(4, 0); // enable the Switcher3v3
    }
 
    // Charge status detect config
    chargeStatus <- ChargeStatus(1);

    // Button config
    hwButton <- PushButton(2);

    // Piezo config
    //hwPiezo <- Piezo(hardware.pin5);

    // Scanner config
    hwScanner <-Scanner(5,6);

    // Microphone sampler config
    hwMicrophone <- EIMP_AUDIO_IN;
    hardware.sampler.configure(hwMicrophone, gAudioSampleRate, 
                               [buf1, buf2, buf3, buf4], 
                               samplerCallback, NORMALISE | A_LAW_COMPRESS); 
                       
    local oldsize = imp.setsendbuffersize(sendBufferSize);
	server.log("send buffer size: new= " + sendBufferSize + " bytes, old= "+oldsize+" bytes.");        
    // Accelerometer config
    hwAccelerometer <- Accelerometer(I2C_IF, 0x18, 
                                     0);

    // Create our timers
    gButtonTimer <- CancellableTimer(cButtonTimeout, 
                                     hwButton.handleButtonTimeout.bindenv(
                                         hwButton)
                                    );
    gDeepSleepTimer = CancellableTimer(cActualDelayBeforeDeepSleep, preSleepHandler);
    
    gAccelHysteresis <- CancellableTimer( 2, sleepHandler); 
    
    
    // Transition to the idle state
    updateDeviceState(DeviceState.IDLE);
    // Print debug info
    // WARNING: for some reason, if this is uncommented, the device
    // will not wake up if there is motion while the device goes 
    // to sleep!
    //printStartupDebugInfo();
	// free memory
    //log(format("Free memory: %d bytes", imp.getmemoryfree()));
    // Initialization complete notification
    // TODO remove startup tone for final product
    // initialize the nv items on a cold boot

    // This means we had already went to sleep with the button presses
    // to get the device back into blink up mode after the blink-up mode times out
    // the user needs to manually enable it the next time it wakes up
    //imp.enableblinkup(false); 
    // We only wake due to an interrupt or after power loss.  If the 
	// former, we need to handle any pending interrupts. 
	//intHandler.handlePin1Int();     
	//gInitTime.init_stage1 = hardware.millis() - gInitTime.init_stage1;
    init_completed = true;
}

function onConnected(status)
{
	gIsConnecting = false;
	
    if (status == SERVER_CONNECTED) {
	if (imp.getbssid() == FACTORY_BSSID) {
	    if (gDeepSleepTimer) 
		gDeepSleepTimer.disable();
	    gDeepSleepTimer = CancellableTimer(cDelayBeforeDeepSleepFactory, preSleepHandler);
	}
        local timeToConnect = hardware.millis() - entryTime;
    	connection_available = true;
        //imp.configure("hiku", [], []);   // this is depcrecated  
		log(format("Reconnected after unexpected disconnect: %d ",nv.disconnect_reason));
		init_nv_items();
		 							             
        	// Send the agent our impee ID
        local data = { 
        				impeeId = hardware.getdeviceid(), 
        				fw_version = cFirmwareVersion,
        				bootup_reason = nv.boot_up_reason,
        				disconnect_reason = nv.disconnect_reason,
        				rssi = imp.rssi(),
        				sleep_duration = nv.sleep_duration,
        				osVersion = imp.getsoftwareversion(),
						time_to_connect = timeToConnect,
                                                at_factory = (imp.getbssid() == FACTORY_BSSID),
	                                        macAddress = imp.getmacaddress()
        			};
        agentSend("init_status", data);
        
        if( nv.setup_required )
        {
        	nv.setup_required = false;
	        nv.sleep_not_allowed = false;
        	nv.setup_count++;
        	log("Setup Completed!");
        }
        nv.disconnect_reason = 0;
        
/*
    	log(format("total_init:%d, init_stage1: %d, init_stage2: %d, init_unused: %d\n",
    		(hardware.millis() - entryTime), gInitTime.init_stage1, gInitTime.init_stage2, gInitTime.init_unused));
    	log(format("scanner:%d, button: %d, charger: %d, accel: %d, int handler: %d\n",
    		gInitTime.scanner, gInitTime.button, gInitTime.charger, gInitTime.accel, gInitTime.inthandler));  */    		      
        
	}
    else
    {
   		nv.disconnect_reason = status;
    }
}	

// start off here and things should move
// Piezo config
hwPiezo <- Piezo(EIMP_AUDIO_OUT); 
if (imp.getssid() == "" && !("first_boot" in nv)) {
    nv.first_boot <- 1;
    nv.setup_required = true;
    imp.deepsleepfor(1);
}

init_done();
connMgr <- ConnectionManager();
connMgr.registerCallback(onConnected.bindenv(this));
connMgr.init_connections();	
init();


/*
//hardware.pinM.configure(PWM_OUT, 0.000000083, 0.5);
// enable interrupts
//lymeric.write(0x66, 0x00);
lymeric.write(0x66, 0xFF);
lymeric.write(0x61, 0x00);
lymeric.writeByteString("\x01\x00\x0f");
local source;
while(1){
        source = lymeric.read(0x65);
        if (source != 0) {
          //server.log("reading interrupts");
          local byte_string = lymeric.readByteString(65);
          lymeric.write(0x66, 0xFF);
          lymeric.write(0x61, 0xFF);
          lymeric.write(0x61, 0x00);
          agent.send("testBarcode", byte_string);
        //imp.sleep(0.1);
        }
        
        //lymeric.write(0x66, 0x00);
        //lymeric.write(0x66, 0x01);
}
*/

// STM32 microprocessor firmware updater
// Copyright (c) 2014 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

// CLASS AND FUNCTION DEFS -----------------------------------------------------

function hexdump(data) {
    local i = 0;
    while (i < data.tell()) {
        local line = " ";
        for (local j = 0; j < 8 && i < data.tell(); j++) {
            line += format("%02x ", data[i++]);
        }
        server.log(line);
    }
}

// This class implements the UART bootloader command set
// https://github.com/electricimp/reference/tree/master/hardware/stm32/UART
class Stm32 {    
    static INIT_TIME        = 0.5; // seconds
    static UART_CONN_TIME   = 0.010; // ms, initial UART configuration time
    static TIMEOUT_CMD      = 100; // ms
    static TIMEOUT_ERASE    = 30000; // ms; erases take a long time!
    static TIMEOUT_WRITE    = 1000; // ms
    static TIMEOUT_PROTECT  = 5000; // ms; used when enabling or disabling read or write protect

    static CMD_INIT         = 0x7F;
    static ACK              = 0x79;
    static NACK             = 0x1F;
    static CMD_GET          = 0x00;
    static CMD_GET_VERSION_PROT_STATUS = 0x01;
    static CMD_GETID       = 0x02;
    static CMD_RD_MEM    = 0x11;
    static CMD_GO           = 0x21;
    static CMD_WR_MEM    = 0x31;
    static CMD_ERASE        = 0x43; // ERASE and EXT_ERASE are exclusive; only one is supported
    static CMD_EXT_ERASE    = 0x44;
    static CMD_WR_PROT      = 0x63;
    static CMD_WR_UNPROT    = 0x73;
    static CMD_RDOUT_PROT   = 0x82;
    static CMD_RDOUT_UNPROT = 0x92;
    
    static FLASH_BASE_ADDR  = 0x08000000;
    static WRSIZE = 256; // max bytes per write
    static SECTORSIZE = 0x4000; // size of one flash "page"
    

    bootloader_version = null;
    bootloader_active = false;
    supported_cmds = [];
    pid = null;
    mem_ptr = 0;
    
    uart = null;
    nrst = null;
    boot0 = null;
    boot1 = null;
    
    constructor(_uart, _nrst, _boot0, _boot1 = null) {
        uart = _uart;
        nrst = _nrst;
        boot0 = _boot0;
        if (_boot1) { boot1 = _boot1; }
        mem_ptr = FLASH_BASE_ADDR;
        clearUart();
    }
    
    // Helper function: clear the UART RX FIFO by reading out any remaining data
    // Input: None
    // Return: None
    function clearUart() {
        uart.configure(BAUD, 8, PARITY_EVEN, 1, NO_CTSRTS);
        
        local byte = uart.read();
        while (byte != -1) {
            byte = uart.read();
        }
    }
    
    // Helper function: block and read a set number of bytes from the UART
    // Times out if the UART doesn't receive the required number of bytes in 2 * BYTE TIME
    // Helpful primarily when reading more than the UART RX FIFO can hold (80 bytes)
    // Input: num_bytes (integer)
    // Return: RX'd data (blob)
    function readUart(num_bytes) {
        local result = blob(num_bytes);
        local start = hardware.millis();
        local pos = result.tell();
        local timeout = 10 * BYTE_TIME * num_bytes * 1000;
        while (result.tell() < num_bytes) {
            if (hardware.millis() - start > timeout) {
                throw format("Timed out waiting for data, got %d / %d bytes",pos,num_bytes);
            }
            local byte = uart.read();
            if (byte != -1) {
                result.writen(byte,'b');
                pos++;
            }
        }
        return result;
    }
    
    // Helper function: compute the checksum for a blob and write the checksum to the end of the blob
    // Note that STM32 checksum is really just a parity byte
    // Input: data (blob)
    //      Blob pointer should be at the end of the data to checksum
    // Return: data (blob), with checksum written to end
    function wrChecksum(data) {
        local checksum = 0;
        for (local i = 0; i < data.tell(); i++) {
            //server.log(format("%02x",data[i]));
            checksum = (checksum ^ data[i]) & 0xff;
        }
        data.writen(checksum, 'b');
    }
    
    // Helper function: send a UART bootloader command
    // Not all commands can use this helper, as some require multiple steps
    // Sends command, gets ACK, and receives number of bytes indicated by STM32
    // Input: cmd - USART bootloader command (defined above)
    // Return: response (blob) - results of sending command
    function sendCmd(cmd) {
        clearUart();
        local checksum = (~cmd) & 0xff;
        uart.write(format("%c%c",cmd,checksum));
        getAck(TIMEOUT_CMD);
        imp.sleep(BYTE_TIME * 2);
        local num_bytes = uart.read() + 0;
        if (cmd == CMD_GETID) {num_bytes++;} // getId command responds w/ number of bytes in ID - 1.
        imp.sleep(BYTE_TIME * (num_bytes + 4));
        
        local result = blob(num_bytes);
        for (local i = 0; i < num_bytes; i++) {
            result.writen(uart.read(),'b');
        }
        
        result.seek(0,'b');
        return result;
    }
    
    // Helper function: wait for an ACK from STM32 when sending a command
    // Implements a timeout and blocks until ACK is received or timeout is reached
    // Input: [optional] timeout in �s
    // Return: bool. True for ACK, False for NACK.
    function getAck(timeout) {
        local byte = uart.read();
        local start = hardware.millis();
        while ((hardware.millis() - start) < timeout) {
            // server.log(format("Looking for ACK: %02x",byte));
            if (byte == ACK) { return true; }
            if (byte == NACK) { return false; }
            if (byte != -1) { server.log(format("%02x",byte)); }
            byte = uart.read();
        }
        throw "Timed out waiting for ACK after "+timeout+" ms";
    }
    
    // set the class's internal pointer for the current address in flash
    // this allows functions outside the class to start at 0 and ignore the flash base address
    // Input: relative position of flash memory pointer (integer)
    // Return: None
    function setMemPtr(addr) {
        mem_ptr = addr + FLASH_BASE_ADDR;
    }
    
    // get the relative position of the current address in flash
    // Input: None
    // Return: relative position of flash memory pointer (integer)
    function getMemPtr() {
        return mem_ptr - FLASH_BASE_ADDR;
    }
    
    // get the base address of flash memory
    // Input: None
    // Return: flash base address (integer)
    function getFlashBaseAddr() {
        return FLASH_BASE_ADDR;
    }
    
    // Reset the STM32 to bring it out of USART bootloader
    // Releases the boot0 pin, then toggles reset
    // Input: None
    // Return: None
    function reset() {
        bootloader_active = false;
        nrst.write(0);
        // release boot0 so we don't come back up in USART bootloader mode
        boot0.write(0);
        imp.sleep(0.010);
        nrst.write(1);
    }
    
    // Reset the STM32 and bring it up in USART bootloader mode
    // Applies "pattern1" from "STM32 system memory boot mode� application note (AN2606)
    // Note that the USARTs available for bootloader vary between STM32 parts
    // Input: None
    // Return: None
    function enterBootloader() {
        // hold boot0 high, boot1 low, and toggle reset
        nrst.write(0);
        boot0.write(1);
        if (boot1) { boot1.write(0); }
        nrst.write(1);
        // bootloader will take a little time to come up
        imp.sleep(INIT_TIME);
        // release boot0 so we don't wind up back in the bootloader on our next reset
        boot0.write(0);
        // send a command to initialize the bootloader on this UART
        clearUart();
        uart.write(CMD_INIT);
        imp.sleep(UART_CONN_TIME);
        local response = uart.read() + 0;
        if (response == ACK) {
            // USART bootloader successfully configured
            bootloader_active = true;
            return;
        } else {
            throw "Failed to configure USART Bootloader, got "+response;
        }
    }
    
    // Send the GET command to the STM32
    // Gets the bootloader version and a list of supported commands
    // The imp will store the results of this command to save time if asked again later
    // Input: None
    // Return: Result (table)
    //      bootloader_version (byte)
    //      supported_cmds (array)
    function get() {
        // only request info from the device if we don't already have it
        if (bootloader_version == null || supported_cmds.len() == 0) {
            // make sure the bootloader is active; allows us to call this method directly from outside the class
            if (!bootloader_active) { enterBootloader(); }
            local result = sendCmd(CMD_GET);
            bootloader_version = result.readn('b');
            bootloader_version = format("%d.%d",((bootloader_version & 0xf0) >> 4),(bootloader_version & 0x0f)).tofloat();
            while (!result.eos()) {
                local byte  = result.readn('b');
                supported_cmds.push(byte);
            }
        } 
        return {bootloader_version = bootloader_version, supported_cmds = supported_cmds};
    }
    
    // Send the GET ID command to the STM32
    // Gets the chip ID from the device
    // The imp will store the results of this command to save time if asked again later
    // Input: None
    // Return: pid (2 bytes)
    function getId() {
        // just return the value if we already know it
        if (pid == null) {
            // make sure bootloader is active before sending command
            if (!bootloader_active) { enterBootloader(); }
            local result = sendCmd(CMD_GETID);
            pid = result.readn('w');
        }
        return format("%04x",pid);
    }
    
    // Read a section of device memory
    // Input: 
    //      addr: 4-byte address. Refer to �STM32 microcontroller system memory boot mode� application note (AN2606) for valid addresses
    //      len: number of bytes to read. 0-255.
    // Return: 
    //      memory contents from addr to addr+len (blob)
    function rdMem(addr, len) {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_RD_MEM, (~CMD_RD_MEM) & 0xff));
        getAck(TIMEOUT_CMD);
        // read mem command ACKs, then waits for starting memory address
        local addrblob = blob(5);
        addrblob.writen(addr,'i');
        addrblob.swap4(); // STM32 wants MSB-first. Imp is LSB-first.
        wrChecksum(addrblob);
        uart.write(addrblob);
        if (!getAck(TIMEOUT_CMD)) {
            throw format("Read Failed for addr %08x (invalid address)",addr);
        };
        // STM32 ACKs the address, then waits for the number of bytes to read
        len = len & 0xff;
        uart.write(format("%c%c",len, (~len) & 0xff));
        if (!getAck(TIMEOUT_CMD)) {
            throw format("Read Failed for %d bytes starting at %08x (read protected)",len,addr);
        }
        // blocking read the memory contents
        local result = readUart(len);
        return result;
    }
    
    // Execute downloaded or other code by branching to a specified address
    // When the address is valid and the command is executed: 
    // - registers of all peripherals used by bootloader are reset to default values
    // - user application's main stack pointer is initialized
    // - STM32 jumps to memory location specified + 4
    // Host should send base address where the application to jump to is programmed
    // Jump to application only works if the user application sets the vector table correctly to point to application addr
    // Input: 
    //      addr: 4-byte address
    // Return: None
    function go(addr = null) {
        if (!bootloader_active) { enterBootloader(); }
        clearUart()
        uart.write(format("%c%c",CMD_GO, (~CMD_GO) & 0xff));
        getAck(TIMEOUT_CMD);
        // GO command ACKs, then waits for starting address
        // if no address was given, assume image starts at the beginning of the flash
        if (addr == null) { addr = FLASH_BASE_ADDR; }
        local addrblob = blob(5);
        addrblob.writen(addr,'i');
        addrblob.swap4(); // STM32 wants MSB-first. Imp is LSB-first.
        wrChecksum(addrblob);
        uart.write(addrblob);        
        if (!getAck(TIMEOUT_CMD)) {
            throw format("Write Failed for addr %08x (invalid address)",addr);
        };
        // system will now exit bootloader and jump into application code
        bootloader_active = false;
        setMemPtr(0);
    }
    
    // Write data to any valid memory address (RAM, Flash, Option Byte Area, etc.)
    // Note: to write to option byte area, address must be base address of this area
    // Maximum length of block to be written is 256 bytes
    // Input: 
    //      addr: 4-byte starting address
    //      data: data to write (0 to 256 bytes, blob)
    // Return: None
    function wrMem(data, addr = null) {
        if (!bootloader_active) { enterBootloader(); }
        if (addr == null) { addr = mem_ptr; }
        data.seek(0,'b');
    
        while (!data.eos()) {
            local bytes_left = data.len() - data.tell();
            local bytes_to_write = bytes_left > WRSIZE ? WRSIZE : bytes_left;
            local buffer = data.readblob(bytes_to_write);
            
            clearUart();
            uart.write(format("%c%c",CMD_WR_MEM, (~CMD_WR_MEM) & 0xff));
            getAck(TIMEOUT_CMD);
        
            // read mem command ACKs, then waits for starting memory address
            local addrblob = blob(5);
            addrblob.writen(mem_ptr,'i');
            addrblob.swap4(); // STM32 wants MSB-first. Imp is LSB-first.
            wrChecksum(addrblob);
            uart.write(addrblob);
            if (!getAck(TIMEOUT_CMD)) {
                throw format("Got NACK on wrMemORY for addr %08x (invalid address)",addr);
            };
            
            // STM32 ACKs the address, then waits for the number of bytes to be written
            local wrblob = blob(buffer.len() + 2);
            wrblob.writen(buffer.len() - 1,'b');
            wrblob.writeblob(buffer);
            wrChecksum(wrblob);
            uart.write(wrblob);
            
            if(!getAck(TIMEOUT_WRITE)) {
                throw "Write Failed (NACK)";
            }
            mem_ptr += bytes_to_write;
        }
    }
    
    // Erase flash memory pages
    // Note that either ERASE or EXT_ERASE are supported, but not both
    // The STM32F407VG does not support ERASE
    // Input:
    //      num_pages (1-byte integer) number of pages to erase
    //      page_codes (array)
    // Return: None
    function eraseMem(num_pages, page_codes) {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_ERASE, (~CMD_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        local erblob = blob(page_codes.len() + 2);
        erblob.writen(num_pages & 0xff, 'b');
        foreach (page in page_codes) {
            erblob.writen(page & 0xff, 'b');
        }
        wrChecksum(erblob);
        uart.write(wrblob);
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Erase Failed (NACK)";
        }
    }
    
    // Erase all flash memory
    // Note that either ERASE or EXT_ERASE are supported, but not both
    // The STM32F407VG does not support ERASE
    // Input: None
    // Return: None
    function eraseGlobalMem() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_ERASE, (~CMD_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\x00");
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Global Erase Failed (NACK)";
        }
    }
    
    // Erase flash memory pages using two byte addressing
    // Note that either ERASE or EXT_ERASE are supported, but not both
    // The STM32F407VG does not support ERASE
    // Input: 
    //      page codes (array of 2-byte integers). List of "sector codes"; leading bytes of memory address to erase.
    // Return: None
    function extEraseMem(page_codes) {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0)
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        // 2 bytes for num_pages, 2 bytes per page code, 1 byte for checksum
        local num_pages = page_codes.len() - 1; // device erases N + 1 pages (grumble)
        local erblob = blob((2 * num_pages) + 3);
        erblob.writen((num_pages & 0xff00) >> 8, 'b');
        erblob.writen(num_pages & 0xff, 'b');
        foreach (page in page_codes) {
            erblob.writen((page & 0xff00) >> 8, 'b');
            erblob.writen(page & 0xff, 'b');
        }
        wrChecksum(erblob);
        uart.write(erblob);
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Extended Erase Failed (NACK)";
        }
    }
    
    // Erase all flash memory for devices that support EXT_ERASE
    // Input: None
    // Return: None
    function massErase() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\xff\x00");
        local byte = uart.read();
        local start = hardware.millis();
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Mass Erase Failed (NACK)";
        }
    }
    
    // Erase bank 1 flash memory for devices that support EXT_ERASE
    // Input: None
    // Return: None
    function bank1Erase() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\xfe\x01");
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Bank 1 Erase Failed (NACK)";
        }
        setMemPtr(0);
    }
    
    // Erase bank 2 flash memory for devices that support EXT_ERASE
    // Input: None
    // Return: None    
    function bank2Erase() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\xfd\x02");
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Bank 2 Erase Failed (NACK)";
        }
    }
    
    // Enable write protection for some or all flash memory sectors
    // System reset is generated at end of command to apply the new configuration
    // Input: 
    //      num_sectors: (1-byte integer) number of sectors to protect
    //      sector_codes: (1-byte integer array) sector codes of sectors to protect
    // Return: None
    function wrProt(num_sectors, sector_codes) {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_WR_PROT, (~CMD_WR_PROT) & 0xff));
        getAck(TIMEOUT_CMD);
        local protblob = blob(sector_codes.len() + 2);
        protblob.writen(num_sectors & 0xff, 'b');
        foreach (sector in sector_codes) {
            protblob.writen(sector & 0xff, 'b');
        }
        wrChecksum(protblob);
        uart.write(protblob);
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Write Protect Unprotect Failed (NACK)";
        }
        // system will now reset
        bootloader_active = false;
        imp.sleep(INIT_TIME);
        enterBootloader();
    }
    
    // Disable write protection of all flash memory sectors
    // System reset is generated at end of command to apply the new configuration
    // Input: None
    // Return: None
    function wrUnprot() {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_WR_UNPROT, (~CMD_WR_UNPROT) & 0xff));
        // first ACK acknowledges command
        getAck(TIMEOUT_CMD);
        // second ACK acknowledges completion of write protect enable
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Write Unprotect Failed (NACK)"
        }
        // system will now reset
        bootloader_active = false;
        imp.sleep(INIT_TIME);
        enterBootloader();
        setMemPtr(0);
    }
    
    // Enable flash memory read protection
    // System reset is generated at end of command to apply the new configuration
    // Input: None
    // Return: None
    function rdProt() {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_RDOUT_PROT, (~CMD_RDOUT_PROT) & 0xff));
        // first ACK acknowledges command
        getAck(TIMEOUT_CMD);
        // second ACK acknowledges completion of write protect enable
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Read Protect Failed (NACK)"
        }        
        // system will now reset
        bootloader_active = false;
        imp.sleep(SYS_RESET_WAIT);
        enterBootloader();
    }
    
    // Disable flash memory read protection
    // System reset is generated at end of command to apply the new configuration
    // Input: None
    // Return: None
    function rdUnprot() {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_RDOUT_UNPROT, (~CMD_RDOUT_UNPROT) & 0xff));
        // first ACK acknowledges command
        getAck(TIMEOUT_CMD);
        // second ACK acknowledges completion of write protect enable
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Read Unprotect Failed (NACK)";
        }
        // system will now reset
        bootloader_active = false;
        imp.sleep(INIT_TIME);
        enterBootloader();
        setMemPtr(0);
    }
}

// AGENT CALLBACKS -------------------------------------------------------------

// Allow the agent to request that the device send its bootloader version and supported commands
agent.on("get_version", function(dummy) {
    agent.send("set_version",stm32.get());
    if (stm32.bootloader_active) { stm32.reset(); }
});

// Allow the agent to request the device's PID
agent.on("get_id", function(dummy) {
    agent.send("set_id", stm32.getId());
    if (stm32.bootloader_active) { stm32.reset(); }
});

// Allow the agent to reset the stm32 to normal operation
agent.on("reset", function(dummy) {
    stm32.reset();
});

// Allow the agent to erase the full STM32 flash 
// Useful for device recovery if something goes wrong during testing
agent.on("erase_stm32", function(dummy) {
    server.log("Enabling Flash Erase");
    stm32.wrUnprot();
    server.log("Erasing All STM32 Flash");
    stm32.massErase();
    server.log("Resetting STM32");
    stm32.reset();
    server.log("Done");
});

// Initiate an application firmware update
agent.on("load_fw", function(len) {
    server.log(format("FW Update: %d bytes",len));
    stm32.enterBootloader();
    local page_codes = [];
    local erase_through_sector = math.ceil((len * 1.0) / STM32_SECTORSIZE);
    for (local i = 0; i <= erase_through_sector; i++) {
        page_codes.push(i);
    }
    server.log(format("FW Update: Erasing %d page(s) in Flash (%d bytes each)", erase_through_sector, STM32_SECTORSIZE));
    stm32.extEraseMem(page_codes);
    stm32.setMemPtr(0);
    server.log("FW Update: Starting Download");
    // send pull request with a dummy value
    agent.send("pull", 0);
});

// used to load new application firmware; device sends a block of data to the stm32,
// then requests another block from the agent with "pull". Agent responds with "push".
agent.on("push", function(buffer) {
    stm32.wrMem(buffer);
    // send pull request with a dummy value
    agent.send("pull", 0);
});

// agent sends this event when the device has downloaded the entire new firmware image
// the device can then reset or send the GO command to start execution
agent.on("dl_complete", function(dummy) {
    server.log("FW Update: Complete, Resetting");
    // can use the GO command to jump right into flash and run
    stm32.go();
    // Or, you can just reset the device and it'll come up and run the new application code
    //stm32.reset();
    server.log("Running");
});

// MAIN ------------------------------------------------------------------------

// enable clock to STM32F0
IMP_ST_CLK.configure(PWM_OUT, 0.000000125, 0.5);

nrst.configure(DIGITAL_OUT);
nrst.write(0);
boot0.configure(DIGITAL_OUT);
boot0.write(0);

//uart.configure(BAUD, 8, PARITY_EVEN, 1, NO_CTSRTS);

stm32 <- Stm32(AUDIO_UART, nrst, boot0);

server.log("Ready");
server.log(imp.getsoftwareversion());

/*
server.log("**************************** STARTING SPI TESTS *********************************************");
hardware.spiflash.enable();
server.log(format("SPI Chip ID: 0x%x", hardware.spiflash.chipid()));

local samples = blob();
local read_samples = blob();
//hardware.spiflash.erasesector(4096);

//samples.writestring("Hello World! ***");
for (local i=0; i<1024;i++)
  samples.writen(math.rand(), 'i');
server.log(format("blob length %d", samples.len()));
local sec_offs = 4096;
for (local i=0; i<16;i++)
  hardware.spiflash.erasesector(sec_offs*(i+1));
local write_start = hardware.millis();
for (local i=0; i<16;i++)
  hardware.spiflash.write(sec_offs*(i+1), samples);
write_start = hardware.millis() - write_start;
server.log(format("Writing 128kB to flash took %d ms", write_start));
//hardware.spiflash.write(4096, samples);
//read_samples = hardware.spiflash.read(4096, 15);
//server.log(format("Read back: %s", read_samples.tostring()));
hardware.spiflash.disable();
*/