// This agent gathers data from the device and pushes to Wunderground
// Talks to wunderground rapid fire server (updates of up to once every 10 sec)
// by: Nathan Seidle
//     SparkFun Electronics
// date: October 4, 2013
// license: BeerWare
//          Please use, reuse, and modify this code as you need.
//          We hope it saves you some time, or helps you learn something!
//          If you find it handy, and we meet some day, you can buy me a beer or iced tea in return.

// Example incoming serial string from device: 
// $,winddir=270,windspeedmph=0.0,windgustmph=0.0,windgustdir=0,windspdmph_avg2m=0.0,winddir_avg2m=12,windgustmph_10m=0.0,windgustdir_10m=0,humidity=998.0,tempf=-1766.2,rainin=0.00,dailyrainin=0.00,pressure=-999.00,batt_lvl=16.11,light_lvl=3.32,#


local STATION_ID = "IVICTORI1278";
local STATION_PW = "<password>"; //Note that you must only use alphanumerics in your password. Http post won't work otherwise.

local LOCAL_ALTITUDE_METERS = 560; // Value from Wunderground

local midnightReset = false; //Keeps track of a once per day cumulative rain reset

local local_hour_offset = 10;

const MAX_PROGRAM_SIZE = 0x20000;
const ARDUINO_BLOB_SIZE = 128;
program <- null;

//------------------------------------------------------------------------------------------------------------------------------
html <- @"<HTML>
<BODY>

<form method='POST' enctype='multipart/form-data'>
Program the ATmega328 via the Imp.<br/><br/>
Step 1: Select an Intel HEX file to upload: <input type=file name=hexfile><br/>
Step 2: <input type=submit value=Press> to upload the file.<br/>
Step 3: Check out your Arduino<br/>
</form>

</BODY>
</HTML>
";

//------------------------------------------------------------------------------------------------------------------------------
// Parses a HTTP POST in multipart/form-data format
function parse_hexpost(req, res) {
    local boundary = req.headers["content-type"].slice(30);
    local bindex = req.body.find(boundary);
    local hstart = bindex + boundary.len();
    local bstart = req.body.find("\r\n\r\n", hstart) + 4;
    local fstart = req.body.find("\r\n\r\n--" + boundary + "--", bstart);
    return req.body.slice(bstart, fstart);
}


//------------------------------------------------------------------------------------------------------------------------------
// Parses a hex string and turns it into an integer
function hextoint(str) {
    local hex = 0x0000;
    foreach (ch in str) {
        local nibble;
        if (ch >= '0' && ch <= '9') {
            nibble = (ch - '0');
        } else {
            nibble = (ch - 'A' + 10);
        }
        hex = (hex << 4) + nibble;
    }
    return hex;
}


//------------------------------------------------------------------------------------------------------------------------------
// Breaks the program into chunks and sends it to the device
function send_program() {
    if (program != null && program.len() > 0) {
        local addr = 0;
        local pline = {};
        local max_addr = program.len();
        
        device.send("burn", {first=true});
        while (addr < max_addr) {
            program.seek(addr);
            pline.data <- program.readblob(ARDUINO_BLOB_SIZE);
            pline.addr <- addr / 2; // Address space is 16-bit
            device.send("burn", pline)
            addr += pline.data.len();
        }
        device.send("burn", {last=true});
    }
}

//------------------------------------------------------------------------------------------------------------------------------
// Parse the hex into an array of blobs
function parse_hexfile(hex) {
    
    try {
        // Look at this doc to work out what we need and don't. Max is about 122kb.
        // https://bluegiga.zendesk.com/entries/42713448--REFERENCE-Updating-BLE11x-firmware-using-UART-DFU
        server.log("Parsing hex file");
        
        // Create and blank the program blob
        program = blob(0x20000); // 128k maximum
        for (local i = 0; i < program.len(); i++) program.writen(0x00, 'b');
        program.seek(0);
        
        local maxaddress = 0, from = 0, to = 0, line = "", offset = 0x00000000;
        do {
            if (to < 0 || to == null || to >= hex.len()) break;
            from = hex.find(":", to);
            
            if (from < 0 || from == null || from+1 >= hex.len()) break;
            to = hex.find(":", from+1);
            
            if (to < 0 || to == null || from >= to || to >= hex.len()) break;
            line = hex.slice(from+1, to);
            // server.log(format("[%d,%d] => %s", from, to, line));
            
            if (line.len() > 10) {
                local len = hextoint(line.slice(0, 2));
                local addr = hextoint(line.slice(2, 6));
                local type = hextoint(line.slice(6, 8));

                // Ignore all record types except 00, which is a data record. 
                // Look out for 02 records which set the high order byte of the address space
                if (type == 0) {
                    // Normal data record
                } else if (type == 4 && len == 2 && addr == 0 && line.len() > 12) {
                    // Set the offset
                    offset = hextoint(line.slice(8, 12)) << 16;
                    if (offset != 0) {
                        server.log(format("Set offset to 0x%08X", offset));
                    }
                    continue;
                } else {
                    server.log("Skipped: " + line)
                    continue;
                }

                // Read the data from 8 to the end (less the last checksum byte)
                program.seek(offset + addr)
                for (local i = 8; i < 8+(len*2); i+=2) {
                    local datum = hextoint(line.slice(i, i+2));
                    program.writen(datum, 'b')
                }
                
                // Checking the checksum would be a good idea but skipped for now
                local checksum = hextoint(line.slice(-2));
                
                /// Shift the end point forward
                if (program.tell() > maxaddress) maxaddress = program.tell();
                
            }
        } while (from != null && to != null && from < to);

        // Crop, save and send the program 
        server.log(format("Max address: 0x%08x", maxaddress));
        program.resize(maxaddress);
        send_program();
        server.log("Free RAM: " + (imp.getmemoryfree()/1024) + " kb")
        return true;
        
    } catch (e) {
        server.log(e)
        return false;
    }
    
}


//------------------------------------------------------------------------------------------------------------------------------
// Handle the agent requests
http.onrequest(function (req, res) {
    // return res.send(400, "Bad request");
    // server.log(req.method + " to " + req.path)
    if (req.method == "GET") {
        res.send(200, html);
    } else if (req.method == "POST") {

        if ("content-type" in req.headers) {
            if (req.headers["content-type"].len() >= 19
             && req.headers["content-type"].slice(0, 19) == "multipart/form-data") {
                local hex = parse_hexpost(req, res);
                if (hex == "") {
                    res.header("Location", http.agenturl());
                    res.send(302, "HEX file uploaded");
                } else {
                    device.on("done", function(ready) {
                        res.header("Location", http.agenturl());
                        res.send(302, "HEX file uploaded");                        
                        server.log("Programming completed")
                    })
                    server.log("Programming started")
                    parse_hexfile(hex);
                }
            } else if (req.headers["content-type"] == "application/json") {
                local json = null;
                try {
                    json = http.jsondecode(req.body);
                } catch (e) {
                    server.log("JSON decoding failed for: " + req.body);
                    return res.send(400, "Invalid JSON data");
                }
                local log = "";
                foreach (k,v in json) {
                    if (typeof v == "array" || typeof v == "table") {
                        foreach (k1,v1 in v) {
                            log += format("%s[%s] => %s, ", k, k1, v1.tostring());
                        }
                    } else {
                        log += format("%s => %s, ", k, v.tostring());
                    }
                }
                server.log(log)
                return res.send(200, "OK");
            } else {
                return res.send(400, "Bad request");
            }
        } else {
            return res.send(400, "Bad request");
        }
    }
})


//------------------------------------------------------------------------------------------------------------------------------
// Handle the device coming online
device.on("ready", function(ready) {
    if (ready) send_program();
});

//------------------------------------------------------------------------------------------------------------------------------


// When we hear something from the device, split it apart and post it
device.on("postToInternet", function(dataString) {

    server.log("postToInternet - dataString: " + dataString);

    //Break the incoming string into pieces by comma
    a <- mysplit(dataString,',');

    if(a[0] != "$" || a[16] != "#")
    {
        server.log(format("Error: incorrect frame received (%s, %s)", a[0], a[16]));
        server.log(format("Received: %s)", dataString));
        return(0);
    }

    //Pull the various bits from the blob
    //a[0] is $
    local winddir = a[1];
    local windspeedmph = a[2];
    local windgustmph = a[3];
    local windgustdir = a[4];
    local windspdmph_avg2m = a[5];
    local winddir_avg2m = a[6];
    local windgustmph_10m = a[7];
    local windgustdir_10m = a[8];
    local humidity = a[9];
    local tempf = a[10];
    local rainin = a[11];
    local dailyrainin = a[12];
    local pressure = a[13].tofloat();
    local batt_lvl = a[14];
    local light_lvl = a[15];
    //a[16] is #

    server.log(tempf);

    //Correct for the actual orientation of the weather station
    //For my station the north indicator is pointing due west
    winddir = windCorrect(winddir);
    windgustdir = windCorrect(windgustdir);
    winddir_avg2m = windCorrect(winddir_avg2m);
    windgustdir_10m = windCorrect(windgustdir_10m);

    //Correct for negative temperatures. This is fixed in the latest libraries: https://learn.sparkfun.com/tutorials/mpl3115a2-pressure-sensor-hookup-guide
    currentTemp <- mysplit(tempf, '=');
    local badTempf = currentTemp[1].tointeger();
    if(badTempf > 200)
    {
        local tempc = (badTempf - 32) * 5/9; //Convert F to C
        tempc = (tempc<<24)>>24; //Force this 8 bit value into 32 bit variable
        tempc = ~(tempc) + 1; //Take 2s compliment
        tempc *= -1; //Assign negative sign
        tempf = tempc * 9/5 + 32; //Convert back to F
        tempf = "tempf=" + tempf; //put a string on it
    }

    //Correct for humidity out of bounds
    currentHumidity <- mysplit(humidity, '=');
    if(currentHumidity[1].tointeger() > 99) humidity = "humidity=99";
    if(currentHumidity[1].tointeger() < 0) humidity = "humidity=0";

    //Turn Pascal pressure into baromin (Inches Mercury at Altimeter Setting)
    local baromin = "baromin=" + convertToInHg(pressure);

    //Calculate a dew point
    currentHumidity <- mysplit(humidity, '=');
    currentTempF <- mysplit(tempf, '=');
    local dewptf = "dewptf=" + calcDewPoint(currentHumidity[1].tointeger(), currentTempF[1].tointeger());

    //Now we form the large string to pass to wunderground
    local strMainSite = "http://rtupdate.wunderground.com/weatherstation/updateweatherstation.php";

    local strID = "ID=" + STATION_ID;
    local strPW = "PASSWORD=" + STATION_PW;

    //Form the current date/time
    //Note: .month is 0 to 11!
    local currentTime = date();
    local strCT = "dateutc=";
    strCT += currentTime.year + "-" + format("%02d", currentTime.month + 1) + "-" + format("%02d", currentTime.day);
    strCT += "+" + format("%02d", currentTime.hour) + "%3A" + format("%02d", currentTime.min) + "%3A" + format("%02d", currentTime.sec);
    //Not sure if wunderground expects the + or a %2B. We shall see.
    //server.log(strCT);

    local bigString = strMainSite;
    bigString += "?" + strID;
    bigString += "&" + strPW;
    bigString += "&" + strCT;
    bigString += "&" + winddir;
    bigString += "&" + windspeedmph;
    bigString += "&" + windgustmph;
    bigString += "&" + windgustdir;
    bigString += "&" + windspdmph_avg2m;
    bigString += "&" + winddir_avg2m;
    bigString += "&" + windgustmph_10m;
    bigString += "&" + windgustdir_10m;
    bigString += "&" + humidity;
    bigString += "&" + tempf;
    bigString += "&" + rainin;
    bigString += "&" + dailyrainin;
    bigString += "&" + baromin;
    bigString += "&" + dewptf;
    //bigString += "&" + weather;
    //bigString += "&" + clouds;
    bigString += "&" + "softwaretype=SparkFunWeatherImp"; //Cause we can
    bigString += "&" + "realtime=1"; //You better believe it!
    bigString += "&" + "rtfreq=10"; //Set rapid fire freq to once every 10 seconds
    bigString += "&" + "action=updateraw";

    //Push to Wunderground
    local request = http.post(bigString, {}, "");
    local response = request.sendsync();
    server.log("Wunderground response = " + response.body);
    server.log(batt_lvl + " " + light_lvl);

    //Check to see if we need to send a midnight reset
    checkMidnight(1);

    server.log("Update complete!");
}); 

//Given a string, break out the direction, correct by some value
//Return a string
function windCorrect(direction) {
    temp <- mysplit(direction, '=');

    //My station's North arrow is pointing due west
    //So correct by 90 degrees
    //local dir = temp[1].tointeger() - 90;

    // No correction required
    local dir = temp[1].tointeger();

    if(dir < 0) dir += 360;
    return(temp[0] + "=" + dir);
}

//With relative humidity and temp, calculate a dew point
//From: http://ag.arizona.edu/azmet/dewpoint.html
function calcDewPoint(relativeHumidity, tempF) {
    local tempC = (tempF - 32) * 5 / 9.0;

    local L = math.log(relativeHumidity / 100.0);
    local M = 17.27 * tempC;
    local N = 237.3 + tempC;
    local B = (L + (M / N)) / 17.27;
    local dewPoint = (237.3 * B) / (1.0 - B);

    //Result is in C
    //Convert back to F
    dewPoint = dewPoint * 9 / 5.0 + 32;

    //server.log("rh=" + relativeHumidity + " tempF=" + tempF + " tempC=" + tempC);
    //server.log("DewPoint = " + dewPoint);
    return(dewPoint);
}

function checkMidnight(ignore) {
//Check to see if it's midnight. If it is, send @ to Arduino to reset time based variables

    server.log("checkMidnight");

    //Get the local time that this measurement was taken
    local localTime = calcLocalTime(); 
    server.log("Local hour = " + format("%c", localTime[0]) + format("%c", localTime[1]));

    // If the time is '00:xx' we are past midnight
    if(localTime[0].tochar() == "0" && localTime[1].tochar() == "0")
    {
        if(midnightReset == false)
        {
            server.log("Local hour = " + format("%c", localTime[0]) + format("%c", localTime[1]));
            server.log("Sending midnight reset");
            midnightReset = true; //We should only reset once
            device.send("sendMidnightReset", 1);
        }
    }
    else
    {
        midnightReset = false; //Reset our state
    }
}

//Given pressure in pascals, convert the pressure to Altimeter Setting, inches mercury
function convertToInHg(pressure_Pa)
{
    local pressure_mb = pressure_Pa / 100; //pressure is now in millibars, 1 pascal = 0.01 millibars
    
    local part1 = pressure_mb - 0.3; //Part 1 of formula
    local part2 = 8.42288 / 100000.0;
    local part3 = math.pow((pressure_mb - 0.3), 0.190284);
    local part4 = LOCAL_ALTITUDE_METERS / part3;
    local part5 = (1.0 + (part2 * part4));
    local part6 = math.pow(part5, (1.0/0.190284));
    local altimeter_setting_pressure_mb = part1 * part6; //Output is now in adjusted millibars
    local baromin = altimeter_setting_pressure_mb * 0.02953;
    //server.log(format("%s", baromin));
    return(baromin);
}

//From Hugo: http://forums.electricimp.com/discussion/915/processing-nmea-0183-gps-strings/p1
//You rock! Thanks Hugo!
function mysplit(a, b) {
  local ret = [];
  local field = "";
  foreach(c in a) {
      if (c == b) {
          // found separator, push field
          ret.push(field);
          field="";
      } else {
          field += c.tochar(); // append to field
      }
   }
   // Push the last field
   ret.push(field);
   return ret;
}

//Given UTC time and a local offset and a date, calculate the local time
//Includes a daylight savings time calc for the US
function calcLocalTime()
{
    //Get the time that this measurement was taken
    local utcTime = date();
    server.log("utcTime: " + utcTime);

    local hour = utcTime.hour; //Most of the work will be on the current hour
    server.log("hour: " + hour);

    server.log("local_hour_offset: " + local_hour_offset);

    //Convert UTC hours to local current time using local_hour
    hour += local_hour_offset;
    if(hour >= 24)
        hour -= 24; //Add 24 hours

    local localTime = format("%02d", hour) + "%3A" + format("%02d", utcTime.min) + "%3A" + format("%02d", utcTime.sec);
    server.log("Local time: " + localTime);

    return(localTime);
}
