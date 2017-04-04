
# Playing Audio from Wireshark captures

Source: https://web.archive.org/web/20150609001342/http://blog.gmichael225.com/post/48khz-adventures

* ProCo Momentum Mi8 boxes (ProSound protocol)
* This thing takes 24-bit samples, and here I have 48 lots of 3 8-bit bytes. Doesn't take a genius to realies that's 48 24-bit samples. And the pattern of noise suggests that's 8 channels-worth of 24-bit samples six times over.
* http://sox.sourceforge.net/ (play audio tool)


```

tshark -i6 -T fields -e data \
| cut -c7-12,55-60,103-108,151-156,199-204,247-252 \
| xxd -r -p \
| play -V -B -r 48000 -c1 -v 7 -t s24 -

```


# Dante Audio

* Multicast address 239.255.x.x
* UDP port 4321
* Unicast ports: 14336-14600


# SVSI Audio stream details

* Configure Stereo (2 channel)
* Multicast address 239.255.250.stream_id
* UDP port 50003


# Livewire audio (AES67 protocol)

```python

#!/usr/bin/python
import sys
import os

RTPDUMP_BIN = "/usr/local/bin/rtpdump" # change this if your path is different
PLAY_BIN = "/usr/local/bin/play"       # change this if your path is different

if len(sys.argv) != 2:
    print "Please supply a valid Livewire channel number (1 - 32767). Correct usage: xplay 32767"
    sys.exit(1)
else:
    # Last two address octets of IP (239.192.x.x) pertain to Axia channel ID, e.g. 9999 = 39 15 (hex 27 0F)
    # Axia channel number + base IP (239.192.0.0 [in hex]) 
    multicastAddr = int(sys.argv[1]) + 0xEFC00000
    os.system(RTPDUMP_BIN + " -F payload " + hex(multicastAddr) + "/5004 | " + PLAY_BIN + " -c 2 -r 48000 -b 24 -e signed-integer  -B -t raw -")


```
