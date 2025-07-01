# main.py
"""
Main script for TikSimPro
Generates and publishes viral TikTok videos with physics simulations
"""

import os
import time
import logging
import argparse
from typing import Optional, Any

from src.core.config import Config

# Initialize logger
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(
            "tiksimpro.log", encoding="utf-8"
        ),  # UTF-8 to avoir charmap problems
    ],
)
logger = logging.getLogger("TikSimPro")

# Import components
from src.pipelines.base_pipeline import IPipeline

from src.core.plugin_manager import PluginManager
from src.core.config import DEFAULT_CONFIG


def setup_component(manager: PluginManager, config: Config, comp_name: str) -> Any:
    """
    Configure and create a single plugin
    Check if we need to implement it or not

    Args:
        manager: The plugin manager.
        config: The global config.
        comp_name: The general name of the component to instanciate.

    Returns:
        An instance of the class component.
    """
    try:
        if not config.get(comp_name):
            return

        comp_class = manager.get_plugin(config.get(comp_name).get("name"))

        if comp_class is None:
            logger.error(f"Component {config.get(comp_name).get('name')} not found")
            return

        return comp_class(
            **{
                k: v
                for k, v in config[comp_name]["params"].items()
                if not k.startswith("_comment")
            }
        )
    except:
        raise


def setup_components(config: Config, specific_publisher=None) -> Optional[IPipeline]:
    """
    Configure and initialize all pipeline components

    Args:
        config: Configuration to use
        specific_publisher: If specified, only enable this publisher

    Returns:
        Configured pipeline, or None if error occurs
    """
    try:
        plugin_dirs = [
            "pipelines",
            "trend_analyzers",
            "video_generators",
            "audio_generators",
            "media_combiners",
            "video_enhancers",
            "publishers",
        ]
        manager = PluginManager("src", plugin_dirs)

        # Create pipeline
        pipeline = manager.get_plugin(config.get("pipeline").get("name"), IPipeline)(
            **{
                k: v
                for k, v in config["pipeline"]["params"].items()
                if not k.startswith("_comment")
            }
        )

        # Create and configure trend analyzer
        pipeline.set_trend_analyzer(setup_component(manager, config, "trend_analyzer"))

        # Create and configure video generator
        pipeline.set_video_generator(
            setup_component(manager, config, "video_generator")
        )

        # Create and configure audio generator
        pipeline.set_audio_generator(
            setup_component(manager, config, "audio_generator")
        )

        # Create and configure media combiner
        pipeline.set_media_combiner(setup_component(manager, config, "media_combiner"))

        # Create and configure video enhancer
        pipeline.set_video_enhancer(setup_component(manager, config, "video_enhancer"))

        # Add publishing systems
        if config.get("publishers"):
            for platform, pub_config in config["publishers"].items():
                # Si publisher spécifique demandé, ne charger que celui-là
                if specific_publisher and platform != specific_publisher:
                    logger.info(
                        f"Skipping {platform} (only loading {specific_publisher})"
                    )
                    continue

                if pub_config.get("enabled", False):
                    publisher = setup_component(
                        manager, {"publishers": {platform: pub_config}}, "publishers"
                    )
                    if publisher:
                        pipeline.add_publisher(platform, publisher)
                        logger.info(f"Publisher {platform} loaded and enabled")

        pip = config.get("pipeline").get("params")

        # Configure pipeline
        pipeline_config = {
            "output_dir": pip.get("output_dir", "videos"),
            "auto_publish": pip.get("auto_publish", False),
            "platforms": [
                p
                for p, cfg in config["publishers"].items()
                if cfg.get("enabled", False)
            ],
            "video_duration": (
                pip.get("duration")
                if pip.get("duration")
                else config["video_generator"]["params"].get("duration", 30)
            ),
            "video_dimensions": (
                pip.get("width")[0]
                if pip.get("width")
                else config["video_generator"]["params"].get("width", 1080),
                pip.get("height")[0]
                if pip.get("height")
                else config["video_generator"]["params"].get("height", 1920),
            ),
            "fps": (
                pip.get("fps")
                if pip.get("fps")
                else config["video_generator"]["params"].get("fps", 60)
            ),
        }
        pipeline.configure(pipeline_config)

        return pipeline

    except Exception as e:
        logger.error(f"Error configuring components: {e}")
        import traceback

        traceback.print_exc()
        return None


def run_pipeline(pipeline) -> Optional[str]:
    """
    Execute the content pipeline

    Args:
        pipeline: Pipeline to execute

    Returns:
        Path to generated video, or None if error occurs
    """
    try:
        logger.info("Starting content pipeline...")
        start_time = time.time()

        # Execute pipeline
        result_path = pipeline.execute()

        if not result_path:
            logger.error("Pipeline execution failed")
            return None

        # Calculate execution time
        elapsed_time = time.time() - start_time
        logger.info(f"Pipeline executed in {elapsed_time:.2f} seconds")
        logger.info(f"Video generated: {result_path}")

        return result_path

    except Exception as e:
        logger.error(f"Error executing pipeline: {e}")
        return None


def main():
    """Main function"""
    # Parse command line arguments
    parser = argparse.ArgumentParser(
        description="TikSimPro - Viral TikTok Content Generator"
    )
    parser.add_argument(
        "--config", "-c", type=str, default="config.json", help="Configuration file"
    )
    parser.add_argument("--output", "-o", type=str, help="Output directory")
    parser.add_argument("--duration", "-d", type=int, help="Video duration in seconds")
    parser.add_argument(
        "--resolution", "-r", type=str, help="Video resolution (width:height)"
    )
    parser.add_argument(
        "--publish", "-p", action="store_true", help="Auto-publish video"
    )
    parser.add_argument(
        "--init", "-i", action="store_true", help="Initialize default configuration"
    )
    args = parser.parse_args()

    parser.add_argument(
        "--publisher",
        type=str,
        help="Specific publisher to use (tiktok, youtube, instagram)",
    )

    # Display banner
    logger.info("\n" + "=" * 80)
    logger.info("          TikSimPro - Viral TikTok Content Generator")
    logger.info("=" * 80 + "\n")

    # Initialize default configuration if requested
    if args.init:
        config = DEFAULT_CONFIG
        config.save_config(config)
        logger.info(f"Default configuration created in {args.config}")
        return

    # Load configuration
    if not os.path.exists(args.config):
        logger.info(f"Configuration file {args.config} not found.")
        logger.info("Use --init to create a default configuration.")
        return

    logger.info(f"Loading configuration from: {args.config}")
    config = Config(args.config).load_config()

    # Apply command line arguments
    if args.output:
        config["pipeline"]["params"]["output_dir"] = args.output

    if args.duration:
        config["video_generator"]["params"]["duration"] = args.duration

    if args.resolution:
        try:
            width, height = map(int, args.resolution.split(":"))
            config["video_generator"]["params"]["width"] = width
            config["video_generator"]["params"]["height"] = height
        except ValueError:
            logger.error(f"Invalid resolution format: {args.resolution}")
            return

    if args.publish:
        config["pipeline"]["params"]["auto_publish"] = True

    # Configure and execute pipeline
    pipeline = setup_components(config, specific_publisher=args.publisher)
    if pipeline:
        result_path = run_pipeline(pipeline)

        if result_path:
            logger.info("\n" + "=" * 60)
            logger.info("✅ PROCESSING COMPLETED SUCCESSFULLY!")
            logger.info(f"📹 Video generated: {result_path}")

            if config["pipeline"].get("auto_publish", False):
                if args.publisher:
                    logger.info(f"🚀 Video published to {args.publisher}.")
                else:
                    logger.info("🚀 Video published to configured platforms.")
            else:
                logger.info("💾 Video saved locally (auto_publish=False).")
            logger.info("=" * 60)
        else:
            logger.info("\n Processing failed. Check logs for details.")
    else:
        logger.info("\n Failed to configure pipeline. Check logs for details.")


if __name__ == "__main__":
    main()
