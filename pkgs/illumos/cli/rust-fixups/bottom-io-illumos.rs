    target_os = "illumos" => {
        use crate::collection::DataCollector;

        /// Returns the I/O counters of each mounted disk, keyed as the disk table looks them up (the last component of
        /// the device name): sysinfo's illumos backend reads them from the disk's kstat I/O record.
        pub fn get_io_usage(collector: &DataCollector) -> anyhow::Result<IoHarvest> {
            Ok(collector
                .sys
                .disks
                .iter()
                .map(|disk| {
                    let usage = disk.usage();
                    let name = disk.name().to_string_lossy();
                    (
                        name.split('/').next_back().unwrap_or_default().to_string(),
                        Some(IoData {
                            read_bytes: usage.total_read_bytes,
                            write_bytes: usage.total_written_bytes,
                        }),
                    )
                })
                .collect())
        }
    }
