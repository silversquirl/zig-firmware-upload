# Flash firmware to your Microcontrollers

Based on avrdude (todo: proper attribution. We are using some data from avrdude.conf that's GPL'd), this library can flash firmward to an arduino uno.


### TODO 

- Linux support. Should be trivial to add, we just need to add an API for setting DTR.
- Other target MCUs. I've got Picos and Nanos laying around. ZigEmbeddedGroup might have some sources worth looking at

### Usage

This is intended to be usable from build scripts. It will attempt to detect connected microcontrollers (any contributions that help us detect controllers are welcome! Even just
indicating "unsupported" in the CLI is useful).

After the user has selected a target device, it can generate a std.Target for the build
script to generate a firmware image for. You can upload that image through the API, which will keep a connection ready for flashing as quickly as possible.