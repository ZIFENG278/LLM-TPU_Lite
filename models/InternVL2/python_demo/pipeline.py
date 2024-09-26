import time
import argparse
from PIL import Image
import torchvision.transforms as T
from transformers import AutoTokenizer
from torchvision.transforms.functional import InterpolationMode
import chat
import os

# Preprocess the images
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


def build_transform(input_size):
    MEAN, STD = IMAGENET_MEAN, IMAGENET_STD
    transform = T.Compose([
        T.Lambda(lambda img: img.convert('RGB') if img.mode != 'RGB' else img),
        T.Resize((input_size, input_size),
                 interpolation=InterpolationMode.BICUBIC),
        T.ToTensor(),
        T.Normalize(mean=MEAN, std=STD)
    ])
    return transform


class InternVL2():

    def __init__(self, args):

        # load tokenizer
        print("Load " + args.tokenizer + " ...")
        self.tokenizer = AutoTokenizer.from_pretrained(args.tokenizer,
                                                       trust_remote_code=True)
        self.tokenizer.decode([0])  # warm up

        # preprocess parameters, such as prompt & tokenizer
        self.system_prompt = '<|im_start|>system\n你是由上海人工智能实验室联合商汤科技开发的书生多模态大模型，英文名叫InternVL, 是一个有用无害的人工智能助手。<|im_end|><|im_start|>user\n'
        image_ids = [0] * 256
        system_ids = self.tokenizer.encode(self.system_prompt + "<img>")
        self.system_offset = len(system_ids)
        self.system_prefix = system_ids + image_ids
        self.image_transform = build_transform(448)
        # load model
        self.model = chat.InternVL2()
        self.model.init(0, args.model_path)
        self.SEQLEN = self.model.SEQLEN
        self.ID_EOS = self.tokenizer.eos_token_id
        self.ID_IM_END = self.tokenizer.convert_tokens_to_ids("<|im_end|>")

    def load_image(self, image_file):
        image = Image.open(image_file).convert('RGB')
        pixel_values = self.image_transform(image)
        return pixel_values

    def encode(self):
        if not self.image_str:
            prompt = self.system_prompt + self.input_str + "<|im_end|><|im_start|>assistant\n"
            self.input_ids = self.tokenizer.encode(prompt)
            self.image_offset = 0
            self.pixel_values = []
            return
        self.pixel_values = self.load_image(self.image_str).flatten().tolist()
        self.image_offset = self.system_offset
        prompt_ids = self.tokenizer.encode(
            "</img>{}<|im_end|><|im_start|>assistant\n".format(self.input_str))
        self.input_ids = self.system_prefix + prompt_ids

    def chat(self):
        """
        Start a chat session.
        """
        # Instruct
        print(
            """\n=================================================================
1. If you want to quit, please enter one of [q, quit, exit]
2. To create a new chat session, please enter one of [clear, new]
=================================================================""")
        # Stop Chatting with "exit" input
        while True:
            self.input_str = input("\nQuestion: ")
            # Quit
            if self.input_str in ["exit", "q", "quit"]:
                break
            self.image_str = input("\nImage Path: ")
            print("\nAnswer:")
            if self.image_str:
                if not os.path.exists(self.image_str):
                    print("Can't find image: {}".format(self.image_str))
                    continue
            self.encode()
            # Chat
            first_start = time.time()
            token = self.model.forward_first(self.input_ids, self.pixel_values,
                                             self.image_offset)
            first_end = time.time()
            tok_num = 1
            # Following tokens
            full_word_tokens = []
            text = ""
            while token not in [self.ID_EOS, self.ID_IM_END
                                ] and self.model.token_length < self.SEQLEN:
                full_word_tokens.append(token)
                word = self.tokenizer.decode(full_word_tokens,
                                             skip_special_tokens=True)
                if "�" not in word:
                    if len(full_word_tokens) == 1:
                        pre_word = word
                        word = self.tokenizer.decode(
                            [token, token],
                            skip_special_tokens=True)[len(pre_word):]
                    text += word
                    print(word, flush=True, end="")
                    full_word_tokens = []
                token = self.model.forward_next()
                tok_num += 1
            next_end = time.time()
            first_duration = first_end - first_start
            next_duration = next_end - first_end
            tps = tok_num / next_duration
            print(f"\nFTL: {first_duration:.3f} s")
            print(f"TPS: {tps:.3f} token/s")


def main(args):
    model = InternVL2(args)
    model.chat()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('-m',
                        '--model_path',
                        type=str,
                        required=True,
                        help='path to the bmodel file')
    parser.add_argument('-t',
                        '--tokenizer',
                        type=str,
                        default="../support/token_config",
                        help='path to the tokenizer file')
    args = parser.parse_args()
    main(args)
