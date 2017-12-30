# encoding: ASCII-8BIT
# frozen_string_literal: true

module Protocols; end

# == References
#
# There are a large number of RFCs relevant to the Telnet protocol.
# RFCs 854-861 define the base protocol.  For a complete listing
# of relevant RFCs, see
# http://www.omnifarious.org/~hopper/technical/telnet-rfc.html
# https://github.com/ruby/net-telnet/blob/master/lib/net/telnet.rb

class Protocols::Telnet
    # :stopdoc:
    IAC   = 255.chr # "\377" # "\xff" # interpret as command
    DONT  = 254.chr # "\376" # "\xfe" # you are not to use option
    DO    = 253.chr # "\375" # "\xfd" # please, you use option
    WONT  = 252.chr # "\374" # "\xfc" # I won't use option
    WILL  = 251.chr # "\373" # "\xfb" # I will use option
    SB    = 250.chr # "\372" # "\xfa" # interpret as subnegotiation
    GA    = 249.chr # "\371" # "\xf9" # you may reverse the line
    EL    = 248.chr # "\370" # "\xf8" # erase the current line
    EC    = 247.chr # "\367" # "\xf7" # erase the current character
    AYT   = 246.chr # "\366" # "\xf6" # are you there
    AO    = 245.chr # "\365" # "\xf5" # abort output--but let prog finish
    IP    = 244.chr # "\364" # "\xf4" # interrupt process--permanently
    BREAK = 243.chr # "\363" # "\xf3" # break
    DM    = 242.chr # "\362" # "\xf2" # data mark--for connect. cleaning
    NOP   = 241.chr # "\361" # "\xf1" # nop
    SE    = 240.chr # "\360" # "\xf0" # end sub negotiation
    EOR   = 239.chr # "\357" # "\xef" # end of record (transparent mode)
    ABORT = 238.chr # "\356" # "\xee" # Abort process
    SUSP  = 237.chr # "\355" # "\xed" # Suspend process
    EOF   = 236.chr # "\354" # "\xec" # End of file
    SYNCH = 242.chr # "\362" # "\xf2" # for telfunc calls

    OPT_BINARY         =   0.chr # "\000" # "\x00" # Binary Transmission
    OPT_ECHO           =   1.chr # "\001" # "\x01" # Echo
    OPT_RCP            =   2.chr # "\002" # "\x02" # Reconnection
    OPT_SGA            =   3.chr # "\003" # "\x03" # Suppress Go Ahead
    OPT_NAMS           =   4.chr # "\004" # "\x04" # Approx Message Size Negotiation
    OPT_STATUS         =   5.chr # "\005" # "\x05" # Status
    OPT_TM             =   6.chr # "\006" # "\x06" # Timing Mark
    OPT_RCTE           =   7.chr # "\a"   # "\x07" # Remote Controlled Trans and Echo
    OPT_NAOL           =   8.chr # "\010" # "\x08" # Output Line Width
    OPT_NAOP           =   9.chr # "\t"   # "\x09" # Output Page Size
    OPT_NAOCRD         =  10.chr # "\n"   # "\x0a" # Output Carriage-Return Disposition
    OPT_NAOHTS         =  11.chr # "\v"   # "\x0b" # Output Horizontal Tab Stops
    OPT_NAOHTD         =  12.chr # "\f"   # "\x0c" # Output Horizontal Tab Disposition
    OPT_NAOFFD         =  13.chr # "\r"   # "\x0d" # Output Formfeed Disposition
    OPT_NAOVTS         =  14.chr # "\016" # "\x0e" # Output Vertical Tabstops
    OPT_NAOVTD         =  15.chr # "\017" # "\x0f" # Output Vertical Tab Disposition
    OPT_NAOLFD         =  16.chr # "\020" # "\x10" # Output Linefeed Disposition
    OPT_XASCII         =  17.chr # "\021" # "\x11" # Extended ASCII
    OPT_LOGOUT         =  18.chr # "\022" # "\x12" # Logout
    OPT_BM             =  19.chr # "\023" # "\x13" # Byte Macro
    OPT_DET            =  20.chr # "\024" # "\x14" # Data Entry Terminal
    OPT_SUPDUP         =  21.chr # "\025" # "\x15" # SUPDUP
    OPT_SUPDUPOUTPUT   =  22.chr # "\026" # "\x16" # SUPDUP Output
    OPT_SNDLOC         =  23.chr # "\027" # "\x17" # Send Location
    OPT_TTYPE          =  24.chr # "\030" # "\x18" # Terminal Type
    OPT_EOR            =  25.chr # "\031" # "\x19" # End of Record
    OPT_TUID           =  26.chr # "\032" # "\x1a" # TACACS User Identification
    OPT_OUTMRK         =  27.chr # "\e"   # "\x1b" # Output Marking
    OPT_TTYLOC         =  28.chr # "\034" # "\x1c" # Terminal Location Number
    OPT_3270REGIME     =  29.chr # "\035" # "\x1d" # Telnet 3270 Regime
    OPT_X3PAD          =  30.chr # "\036" # "\x1e" # X.3 PAD
    OPT_NAWS           =  31.chr # "\037" # "\x1f" # Negotiate About Window Size
    OPT_TSPEED         =  32.chr # " "    # "\x20" # Terminal Speed
    OPT_LFLOW          =  33.chr # "!"    # "\x21" # Remote Flow Control
    OPT_LINEMODE       =  34.chr # "\""   # "\x22" # Linemode
    OPT_XDISPLOC       =  35.chr # "#"    # "\x23" # X Display Location
    OPT_OLD_ENVIRON    =  36.chr # "$"    # "\x24" # Environment Option
    OPT_AUTHENTICATION =  37.chr # "%"    # "\x25" # Authentication Option
    OPT_ENCRYPT        =  38.chr # "&"    # "\x26" # Encryption Option
    OPT_NEW_ENVIRON    =  39.chr # "'"    # "\x27" # New Environment Option
    OPT_EXOPL          = 255.chr # "\377" # "\xff" # Extended-Options-List

    NULL = "\000"
    CR   = "\015"
    LF   = "\012"
    EOL  = CR + LF
    REVISION = '$Id$'
    # :startdoc:

    def initialize(block = nil, &blk)
        @write = block || blk
        @binary_mode = false
        @suppress_go_ahead = false
        @buffer = String.new
    end

    def preprocess(string)
        # combine CR+NULL into CR
        string = string.gsub(/#{CR}#{NULL}/no, CR)

        string.gsub(/#{IAC}(
            [#{IAC}#{AO}#{AYT}#{DM}#{IP}#{NOP}]|
            [#{DO}#{DONT}#{WILL}#{WONT}]
            [#{OPT_BINARY}-#{OPT_NEW_ENVIRON}#{OPT_EXOPL}]|
            #{SB}[^#{IAC}]*#{IAC}#{SE}
        )/xno) do
            if IAC == $1  # handle escaped IAC characters
                IAC
            elsif AYT == $1  # respond to "IAC AYT" (are you there)
                @write.call("nobody here but us pigeons" + EOL)
                ''
            elsif DO[0] == $1[0]  # respond to "IAC DO x"
                if OPT_BINARY[0] == $1[1]
                @binary_mode = true
                @write.call(IAC + WILL + OPT_BINARY)
                else
                @write.call(IAC + WONT + $1[1..1])
                end
                ''
            elsif DONT[0] == $1[0]  # respond to "IAC DON'T x" with "IAC WON'T x"
                @write.call(IAC + WONT + $1[1..1])
                ''
            elsif WILL[0] == $1[0]  # respond to "IAC WILL x"
                if OPT_BINARY[0] == $1[1]
                    @write.call(IAC + DO + OPT_BINARY)
                elsif OPT_ECHO[0] == $1[1]
                    @write.call(IAC + DO + OPT_ECHO)
                elsif OPT_SGA[0]  == $1[1]
                    @suppress_go_ahead = true
                    @write.call(IAC + DO + OPT_SGA)
                else
                    @write.call(IAC + DONT + $1[1..1])
                end
                ''
            elsif WONT[0] == $1[0]  # respond to "IAC WON'T x"
                if OPT_ECHO[0] == $1[1]
                    @write.call(IAC + DONT + OPT_ECHO)
                elsif OPT_SGA[0]  == $1[1]
                    @suppress_go_ahead = false
                    @write.call(IAC + DONT + OPT_SGA)
                else
                    @write.call(IAC + DONT + $1[1..1])
                end
                ''
            else
                ''
            end
        end
    end # preprocess

    def buffer(data)
        data = @buffer + data
        if Integer(data.rindex(/#{IAC}#{SE}/no) || 0) < Integer(data.rindex(/#{IAC}#{SB}/no) || 0)
            msg = preprocess(data[0 ... data.rindex(/#{IAC}#{SB}/no)])
            @buffer = data[data.rindex(/#{IAC}#{SB}/no) .. -1]
        elsif pt = data.rindex(/#{IAC}[^#{IAC}#{AO}#{AYT}#{DM}#{IP}#{NOP}]?\z/no) || data.rindex(/\r\z/no)
            msg = preprocess(data[0 ... pt])
            @buffer = data[pt .. -1]
        else
            msg = preprocess(data)
            @buffer = String.new
        end

        msg
    end

    def prepare(command)
        if @binary_mode and @suppress_go_ahead
            # IAC WILL SGA IAC DO BIN send EOL --> CR
            "#{command}#{CR}"
        elsif @suppress_go_ahead
            # IAC WILL SGA send EOL --> CR+NULL
            "#{command}#{CR}#{NULL}"
        else
            # NONE send EOL --> CR+LF
            "#{command}#{EOL}"
        end
    end
end
