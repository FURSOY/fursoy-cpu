#ifndef FURSOY_EMBENCH_BOARDSUPPORT_H
#define FURSOY_EMBENCH_BOARDSUPPORT_H

#ifndef CPU_MHZ
#define CPU_MHZ 1
#endif

#ifndef GLOBAL_SCALE_FACTOR
#define GLOBAL_SCALE_FACTOR 1
#endif

#ifndef WARMUP_HEAT
#define WARMUP_HEAT 1
#endif

void initialise_board(void);
void start_trigger(void);
void stop_trigger(void);

#endif /* FURSOY_EMBENCH_BOARDSUPPORT_H */
