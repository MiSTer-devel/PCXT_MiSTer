# SN76489 Complex Sound Generator

VHDL, BSD 3-Clause

A huge amount of effort has gone into making this core as accurate as possible to the real IC, while at the same time making it usable in all digital SoC designs, i.e. retro-computer and game systems, etc.  Design elements from the real IC were used and implemented when possible, with any work-around or changes noted along with the reasons.

Synthesized and FPGA proven:

  * Xilinx Spartan-6 LX16, SoC 21.477MHz system clock, 3.58MHz clock-enable.


References:

  * The SN76489 datasheet
  * Insight gained from the AY-3-8910/YM-2149 die-shot and reverse-engineered schematics (similar audio chips from the same era).
  * Real hardware (SN76489 in a ColecoVision game console).
  * Chip quirks, use, and abuse details from friends and retro enthusiasts.


Generates:

  * Unsigned 12-bit output for each channel.
  * Unsigned 14-bit summation of the four channels.
  * Signed 14-bit PCM summation of the four channels, with each channel converted to -/+ zero-centered level or -/+ full-range level.

The tone counters are period-limited to prevent the very high frequency outputs that the original IC is capable of producing.  Frequencies above 20KHz cause problems in all-digital systems with sampling rates around 44.1KHz to 48KHz.  The primary use of these high frequencies was as a carrier for amplitude modulated (AM) audio.  The high frequency would be filtered out by external electronics, leaving only the low frequency audio.

When the tone counters are limited, the output square-wave is disabled, but the amplitude can still be changed, which allows the A.M. technique to still work in a digital Soc.

I/O requires at least two clock-enable cycles.  This could be modified to operate faster, i.e. based on the input-clock directly.  All inputs are registered at the system-clock rate.

Optionally simulates the original 32-clock (clock-enable) I/O cycle.

The SN76489 does not have an external reset and the original IC "wakes up" generating a tone.  This implementation sets the default output level to full attenuation (silent output).  If the original functionality is desired, modify the channel period and level register initial values.


## Basic I/O interface use:

  - Set-up data on data_i.
  - Set ce_n_i and wr_n_i low.
  - Observe ready_o and wait for it to become high.
  - Set wr_n_i high, if done writing to the chip set ce_n_i high.
