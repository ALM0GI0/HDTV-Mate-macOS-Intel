/* List every audio format macOS Core Audio can DECODE, and check for AC-4.
 * Build: cc tools/coreaudio_codecs.c -framework AudioToolbox -o coreaudio_codecs */
#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>

static void fourcc(UInt32 v, char *o)
{
	o[0] = v >> 24; o[1] = v >> 16; o[2] = v >> 8; o[3] = v; o[4] = 0;
	for (int i = 0; i < 4; i++) if (o[i] < 32 || o[i] > 126) o[i] = '.';
}

int main(void)
{
	UInt32 size = 0;
	if (AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, NULL, &size)) {
		puts("query failed");
		return 1;
	}
	UInt32 n = size / sizeof(UInt32), ids[n];
	AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, NULL, &size, ids);
	int ac4 = 0, ac3 = 0, ec3 = 0;
	printf("Core Audio decoders (%u):", n);
	for (UInt32 i = 0; i < n; i++) {
		char s[5];
		fourcc(ids[i], s);
		printf(" '%s'", s);
		if (ids[i] == 'ac-4' || ids[i] == 'ac4 ') ac4 = 1;
		if (ids[i] == 'ac-3') ac3 = 1;
		if (ids[i] == 'ec-3') ec3 = 1;
	}
	printf("\n\nAC-3: %s   E-AC-3: %s   AC-4: %s\n", ac3 ? "yes" : "no", ec3 ? "yes" : "no",
	       ac4 ? "YES" : "no");
	return 0;
}
