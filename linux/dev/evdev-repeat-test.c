/*
 * Isolated test of the evdev read path (src/device.c: device_read_event)
 * feeding the keyd engine with the capslock config.
 *
 * Raw struct input_event records (EV_MSC/EV_KEY/EV_SYN, including kernel
 * autorepeat value=2) are written to a pipe instead of /dev/input.
 * Reading mimics src/evloop.c: each "wakeup" gets one timestamp and drains
 * the fd with device_read_event() until it returns NULL, re-polling while
 * data remains. No input device or uinput is opened.
 *
 * usage: evdev-repeat-test <config>
 */
#include <poll.h>
#include <linux/input.h>
#include "keyd.h"

#define MAX_EV 256

static struct key_event out[MAX_EV];
static size_t nout;

static void send_key(uint8_t code, uint8_t pressed)
{
	out[nout].code = code;
	out[nout].pressed = pressed;
	nout++;
}

static void on_layer_change(const struct keyboard *kbd, const struct layer *layer, uint8_t active)
{
}

struct batch {
	int time;
	int n;
	struct input_event ev[64];
};

static void add(struct batch *b, int type, int code, int value)
{
	b->ev[b->n].type = type;
	b->ev[b->n].code = code;
	b->ev[b->n].value = value;
	b->n++;
}

/* One physical key report: MSC_SCAN, EV_KEY, SYN_REPORT. */
static void report(struct batch *b, int code, int value)
{
	add(b, EV_MSC, MSC_SCAN, 0x70039);
	add(b, EV_KEY, code, value);
	add(b, EV_SYN, SYN_REPORT, 0);
}

static int run(const char *name, struct config *config,
	       struct batch *batches, size_t nbatches,
	       const struct key_event *expected, size_t nexpected)
{
	struct output output = { .send_key = send_key, .on_layer_change = on_layer_change };
	struct keyboard *kbd = new_keyboard(config, &output);
	struct key_event in[MAX_EV];
	size_t nin = 0;
	size_t i;
	int pfd[2];
	struct device dev = {0};
	int ok = 1;

	assert(!pipe(pfd));
	fcntl(pfd[0], F_SETFL, O_NONBLOCK);
	dev.fd = pfd[0];

	for (i = 0; i < nbatches; i++) {
		struct pollfd p = { .fd = pfd[0], .events = POLLIN };

		assert(write(pfd[1], batches[i].ev, batches[i].n * sizeof(struct input_event)) ==
		       (ssize_t)(batches[i].n * sizeof(struct input_event)));

		/* evloop: one timestamp per wakeup, drain until NULL, poll again. */
		while (poll(&p, 1, 0) > 0 && (p.revents & POLLIN)) {
			struct device_event *devev;

			while ((devev = device_read_event(&dev))) {
				if (devev->type != DEV_KEY)
					continue;
				in[nin].code = devev->code;
				in[nin].pressed = devev->pressed;
				in[nin].timestamp = batches[i].time;
				nin++;
			}
		}
	}

	nout = 0;
	kbd_process_events(kbd, in, nin);

	if (nout != nexpected)
		ok = 0;
	for (i = 0; ok && i < nout; i++)
		if (out[i].code != expected[i].code || out[i].pressed != expected[i].pressed)
			ok = 0;

	printf("%s %s (engine input events: %zu)\n", name, ok ? "PASSED" : "FAILED", nin);
	if (!ok) {
		printf("  output:");
		for (i = 0; i < nout; i++)
			printf(" %s:%s", KEY_NAME(out[i].code), out[i].pressed ? "down" : "up");
		printf("\n");
	}

	close(pfd[0]);
	close(pfd[1]);
	free(kbd);
	return ok ? 0 : 1;
}

#define N(a) (sizeof(a) / sizeof(a[0]))

int main(int argc, char *argv[])
{
	struct config config;
	int fails = 0;
	int t;
	static struct batch b[64];
	size_t nb;

	if (argc != 2 || config_parse(&config, argv[1])) {
		printf("usage: %s <config>\n", argv[0]);
		return 2;
	}

	/* 1. Hold 600 ms with kernel autorepeat (delay 250, rate 30/s). */
	nb = 0;
	memset(b, 0, sizeof b);
	b[nb].time = 0; report(&b[nb++], KEY_CAPSLOCK, 1);
	for (t = 250; t < 600; t += 33) {
		b[nb].time = t; report(&b[nb++], KEY_CAPSLOCK, 2);
	}
	b[nb].time = 600; report(&b[nb++], KEY_CAPSLOCK, 0);
	b[nb].time = 1000; report(&b[nb], KEY_X, 1); report(&b[nb++], KEY_X, 0);
	{
		struct key_event exp[] = {
			{KEYD_CAPSLOCK, 1}, {KEYD_CAPSLOCK, 0}, {KEYD_X, 1}, {KEYD_X, 0},
		};
		fails += run("hold-600ms-with-autorepeat", &config, b, nb, exp, N(exp));
	}

	/* 2. Press and release queued together (one wakeup, same ms), then idle. */
	nb = 0;
	memset(b, 0, sizeof b);
	b[nb].time = 0; report(&b[nb], KEY_CAPSLOCK, 1); report(&b[nb++], KEY_CAPSLOCK, 0);
	b[nb].time = 1000; report(&b[nb], KEY_X, 1); report(&b[nb++], KEY_X, 0);
	{
		struct key_event exp[] = {
			{KEYD_HANGEUL, 1}, {KEYD_HANGEUL, 0}, {KEYD_X, 1}, {KEYD_X, 0},
		};
		fails += run("tap-batched-same-ms", &config, b, nb, exp, N(exp));
	}

	/* 3. Caps held past timeout while another key autorepeats. */
	nb = 0;
	memset(b, 0, sizeof b);
	b[nb].time = 0; report(&b[nb++], KEY_CAPSLOCK, 1);
	b[nb].time = 400; report(&b[nb++], KEY_X, 1);
	for (t = 650; t < 800; t += 33) {
		b[nb].time = t; report(&b[nb++], KEY_X, 2);
	}
	b[nb].time = 800; report(&b[nb++], KEY_X, 0);
	b[nb].time = 900; report(&b[nb++], KEY_CAPSLOCK, 0);
	{
		struct key_event exp[] = {
			{KEYD_CAPSLOCK, 1}, {KEYD_X, 1}, {KEYD_X, 0}, {KEYD_CAPSLOCK, 0},
		};
		fails += run("hold-with-other-key-autorepeat", &config, b, nb, exp, N(exp));
	}

	/* 4. Stray autorepeat without a press produces nothing. */
	nb = 0;
	memset(b, 0, sizeof b);
	b[nb].time = 0; report(&b[nb++], KEY_CAPSLOCK, 2);
	b[nb].time = 1000; report(&b[nb], KEY_X, 1); report(&b[nb++], KEY_X, 0);
	{
		struct key_event exp[] = { {KEYD_X, 1}, {KEYD_X, 0} };
		fails += run("stray-autorepeat", &config, b, nb, exp, N(exp));
	}

	/* 5. Physical Hangul key (KEY_HANGEUL) with autorepeat acts as Right Alt. */
	nb = 0;
	memset(b, 0, sizeof b);
	b[nb].time = 0; report(&b[nb++], KEY_HANGEUL, 1);
	for (t = 250; t < 400; t += 33) {
		b[nb].time = t; report(&b[nb++], KEY_HANGEUL, 2);
	}
	b[nb].time = 400; report(&b[nb++], KEY_HANGEUL, 0);
	{
		struct key_event exp[] = { {KEYD_RIGHTALT, 1}, {KEYD_RIGHTALT, 0} };
		fails += run("hangul-key-as-rightalt", &config, b, nb, exp, N(exp));
	}

	printf("\n%d failed\n", fails);
	return fails ? 1 : 0;
}
