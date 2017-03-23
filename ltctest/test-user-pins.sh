#!/bin/sh -e
gpio_dir=/sys/class/gpio
status_green=32
status_red=33
mode=34
reset_in=35
all_pins="0 1 2 3 4 5 ${status_green} ${status_red} ${mode} ${reset_in}"
test_program=/tmp/ltctest.wav
uart=/dev/ttyAMA0
baud=9600

pin_to_gpio() {
	pin_num="$1"
	case "${pin_num}" in
		0|0a|0b) echo 4 ;;
		1|1a|1b) echo 17 ;;
		2|2a|2b) echo 27 ;;
		3|3a|3b) echo 22 ;;
		4) echo 5 ;;
		5) echo 6 ;;
		${status_green}) echo 13 ;;
		${status_red}) echo 12 ;;
		${mode}) echo 23 ;;
		${reset_in}) echo 18 ;;
		*) echo "Unrecognized pin: ${pin_num}" ; exit 1; ;;
	esac
}

pulse_range_pin() {
	pin_num="$1"
	case "${pin_num}" in
		0|1|2|3) echo 1024 ;;
		4|5) echo 560 ;;
		rgb) echo 465 ;;
		room) echo 0 ;;
		*) echo "???" ;;
	esac
}

export_pin() {
	pin_num=$(pin_to_gpio "$1")
	if [ -e "${gpio_dir}/gpio${pin_num}" ]
	then
		echo ${pin_num} > /sys/class/gpio/unexport
	fi

	if [ ! -e "${gpio_dir}/gpio${pin_num}" ]
	then
		echo ${pin_num} > /sys/class/gpio/export
	fi
}

set_input() {
	pin_num=$(pin_to_gpio "$1")
	echo "in" > ${gpio_dir}/gpio${pin_num}/direction
}

set_output() {
	pin_num=$(pin_to_gpio "$1")
	echo "out" > ${gpio_dir}/gpio${pin_num}/direction
}

set_low() {
	pin_num=$(pin_to_gpio "$1")
	echo 0 > ${gpio_dir}/gpio${pin_num}/value
}

set_high() {
	pin_num=$(pin_to_gpio "$1")
	echo 1 > ${gpio_dir}/gpio${pin_num}/value
}

get_value() {
	pin_num=$(pin_to_gpio "$1")
	set_input "$1"
	if [ $(cat ${gpio_dir}/gpio${pin_num}/value) = 0 ]
	then
		return 0
	fi
	return 1
}

enter_programming_mode() {
	set_output ${reset_in}
	set_low ${reset_in}
	sleep .5
	set_input ${reset_in}
}

wait_for_green_on() {
	until ! get_value ${status_green} && get_value ${status_red}
	do
		sleep 1
	done
}

wait_for_green_off() {
	until get_value ${status_green} && get_value ${status_red}
	do
		sleep 1
	done
}

pulse_range() {
	center=$(pulse_range_pin "$1")
	range="$2"
	before=$(grep 'pinctrl-bcm2835   2 ' /proc/interrupts  | awk '{print $2}')
	sleep 1
	after=$(grep 'pinctrl-bcm2835   2 ' /proc/interrupts | awk '{print $2}')
	difference=$((${after}-${before}))
	ub=$((${center} + ${range}))
	lb=$((${center} - ${range}))

	range_val="${lb} <= ${difference} <= ${ub}"

	[ ${difference} -lt ${ub} ] && [ ${difference} -gt ${lb} ]
}

####################################################

# Export all pins so that we can use them
for pin in ${all_pins}
do
	export_pin ${pin}
done

if ! pulse_range room 16
then
	echo "Room too bright.  Shield test jig."
	exit 1
fi

# Start out by setting all pins low.
# The bootloader does this, so we're not
# really fighting it here.
echo "Setting up pins..."
echo "    O: 0"
set_output 0
echo "    O: 1"
set_output 1
echo "    O: 2"
set_output 2
echo "    O: 3"
set_output 3
echo "    O: 4"
set_output 4
echo "    O: 5"
set_output 5
echo "    L: 0"
set_low 0
echo "    L: 1"
set_low 1
echo "    L: 2"
set_low 2
echo "    L: 3"
set_low 3
echo "    L: 4"
set_low 4
echo "    L: 5"
set_low 5
echo "    I: G"
set_input ${status_green}
echo "    I: R"
set_input ${status_red}
echo "    I: M"
set_input ${mode}
echo "    I: I"
set_input ${reset_in}

echo "Audio test:"
echo "    Download mode"
enter_programming_mode

if get_value ${status_green} || ! get_value ${status_red}
then
	echo "        Unable to enter download mode"
	exit 1
fi

echo "    Programming"
aplay -q "${test_program}"

# Wait for status_green, which gets turned on
# as soon as the program starts running.
if ! get_value ${status_green} || get_value ${status_red}
then
	echo "        Program never loaded"
	exit 1
fi

# Check to see if serial is working.  Look for the string
# 'test-running', and echo back 'q'.
echo "Serial test:"
stty -F ${uart} ${baud}
echo "    Receiving"
grep -q test-running ${uart}
echo "    Sending"
echo q > ${uart}

# Wait for the device to indicate it's ready.  It does
# this by lighting up the red LED
wait_for_green_off
echo "    Send Acknowledged"

# At this point, the board is waiting for pin 0 to go high.
echo "Pin tests:"
for pin in 0a 0b 1a 1b 2 3a 3b 4 5
do
	echo "    Pin ${pin}"
	set_high ${pin}
	sleep .2
	wait_for_green_on

	set_low ${pin}
	sleep .2
	wait_for_green_off
	set_low ${pin}
done

set_low 0
set_low 1
set_low 2
set_low 3
set_high 4
set_low 5

echo "PWM LED tests:"
for pin in $(seq 0 5)
do
	signal_pin=$(((${pin}+1)%6))
	echo "    Pin A${pin}"
	set_input ${pin}
	set_output ${signal_pin}
	set_low ${signal_pin}
	if ! pulse_range ${pin} 128
	then
		echo "      Pulse out of range: ${range_val}"
	fi
	set_high ${signal_pin}

	set_output ${pin}
	set_low ${pin}
done

echo "RGB LED tests:"
set_output 1
set_low 1

for color in Red Green Blue
do
	set_high 1
	echo "    ${color}"
	if ! pulse_range rgb 128
	then
		echo "Pulse out of range: ${range_val}"
	fi
	set_low 1

	# Turn off the last remaining pin from the PWM test.
	set_low 0
done

echo "All tests passed.  Program with audio test."
