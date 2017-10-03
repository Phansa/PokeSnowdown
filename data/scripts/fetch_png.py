from urllib.request import Request, urlopen 
import json 
import os

def get_sprites (path):
        with open('../pokemon.json') as infile:    
                pokemon = json.load(infile)
        if(not(os.path.isdir("../" + path))):
                os.makedirs("../" + path)
        for pokey in pokemon:
                outputString = pokey
                # These files have changed on the image website but remain in the
                # pokemon json in their old forms. Instead of rewriting other
                # parts of the program this will check the exception cases and
                # correct them
                if pokey == "mewtwo-mega-x":
                        pokey = "mewtwo-megax"
                elif pokey == "mewtwo-mega-y":
                        pokey = "mewtwo-megay"
                elif pokey == "charizard-mega-x":
                        pokey = "charizard-megax"
                elif pokey == "charizard-mega-y":
                        pokey = "charizard-megay"
                elif pokey == "floette-eternalflower":
                        pokey = "floette-eternal"
                if path == "back-sprites-shiny":
                        url = "http://play.pokemonshowdown.com/sprites/xyani-back-shiny/" + pokey + ".gif"
                elif path == "sprites-shiny":
                        url = "http://play.pokemonshowdown.com/sprites/xyani-shiny/" + pokey + ".gif"
                elif path == "back-sprites":
                        url ="http://play.pokemonshowdown.com/sprites/xyani-back/" + pokey + ".gif"
                else:
                        url ="http://play.pokemonshowdown.com/sprites/xyani/" + pokey + ".gif"
                req = Request(url, headers={'User-Agent': 'Mozilla/5.0'})
                # Reverts the changed urls back to a form the rest of the program expects
                if pokey == "mewtwo-megax":
                        name_of_file = "../" + path + "/mewtwo-mega-x.gif"
                elif pokey == "mewtwo-megay":
                        name_of_file = "../" + path + "/mewtwo-mega-y.gif"
                elif pokey == "charizard-megax":
                        name_of_file = "../" + path + "/charizard-mega-x.gif"
                elif pokey == "charizard-megay":
                        name_of_file = "../" + path + "/charizard-mega-y.gif"
                elif pokey == "floette-eternal":
                        name_of_file = "../" + path + "/floette-eternalflower.gif"
                else:
                        name_of_file = "../" + path + "/" + url.split('/')[-1]
                # Only processes files which don't already exist. This is useful
                # as there is a rate limit on the image website that causes connections
                # to be closed. When that happens, we don't want to redownload files.
                if(not(os.path.isfile(name_of_file))):
                        outputString += " - Added"
                        gif = urlopen(req)
                        gif_file = open(name_of_file, 'wb')
                        block_size = 8192
                        while True:
                                buffer = gif.read(block_size)
                                if not buffer:
                                        break
                                gif_file.write(buffer)
                        gif_file.close()
                        print(outputString)

def main():
        get_sprites("back-sprites-shiny")
        get_sprites("sprites-shiny")
        get_sprites("back-sprites")
        get_sprites("sprites")
        
if __name__ == "__main__":
        main()
